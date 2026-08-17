package com.intertec.autoops.agent.loop;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.agent.modelsdk.ModelCredentials;
import com.intertec.autoops.agent.modelsdk.ModelVendor;
import com.intertec.autoops.agent.modelsdk.openai.OpenAiClientFactory;
import com.openai.client.OpenAIClient;
import com.openai.core.JsonValue;
import com.openai.models.FunctionDefinition;
import com.openai.models.FunctionParameters;
import com.openai.models.chat.completions.ChatCompletion;
import com.openai.models.chat.completions.ChatCompletionAssistantMessageParam;
import com.openai.models.chat.completions.ChatCompletionCreateParams;
import com.openai.models.chat.completions.ChatCompletionFunctionTool;
import com.openai.models.chat.completions.ChatCompletionMessageFunctionToolCall;
import com.openai.models.chat.completions.ChatCompletionMessageToolCall;
import com.openai.models.chat.completions.ChatCompletionTool;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * OpenAI, and the five vendors that speak its wire format.
 *
 * <p>The differences from Anthropic are not cosmetic, and each one is a place
 * a shared implementation would have gone wrong:
 *
 * <ul>
 *   <li>the system prompt is the first MESSAGE, not a top-level field;</li>
 *   <li>tool results are one message each with role {@code tool}, so the
 *       neutral {@link ChatMessage.ToolResults} list is fanned back out;</li>
 *   <li>arguments arrive as a JSON STRING that has to be parsed, where
 *       Anthropic hands back a structured object;</li>
 *   <li>there is no {@code is_error} flag, so a failed tool has to say so in
 *       its content or the model never learns it failed.</li>
 * </ul>
 */
@Component
public class OpenAiChatModel implements ChatModel {

    private static final Logger log = LoggerFactory.getLogger(OpenAiChatModel.class);

    private static final TypeReference<Map<String, Object>> MAP_TYPE = new TypeReference<>() { };

    private final ObjectMapper mapper;

    public OpenAiChatModel(ObjectMapper mapper) {
        this.mapper = mapper;
    }

    @Override
    public boolean supports(ModelVendor vendor) {
        return vendor.sdk() == ModelVendor.Sdk.OPENAI;
    }

    @Override
    public ChatResponse chat(Request request) {
        ModelCredentials credentials = request.credentials();
        return chatWith(OpenAiClientFactory.create(credentials), request);
    }

    /**
     * The mapping, against an already-configured client.
     *
     * <p>Split out so {@link HuaweiChatModel} can reuse it: a ModelArts
     * inference service speaks this wire format but is reached through the
     * tenant's own endpoint, so it needs the mapping without the factory.
     */
    ChatResponse chatWith(OpenAIClient client, Request request) {
        ChatCompletionCreateParams.Builder params = ChatCompletionCreateParams.builder()
                .model(request.model())
                .maxCompletionTokens(request.maxTokens());

        // System prompt as the leading message, not a separate field.
        if (request.system() != null && !request.system().isBlank()) {
            params.addSystemMessage(request.system());
        }
        for (ToolSpec spec : request.tools()) {
            params.addTool(toTool(spec));
        }
        appendMessages(params, request.messages());

        ChatCompletion completion = client.chat().completions().create(params.build());
        return toChatResponse(completion);
    }

    // ----------------------------------------------------------- request ---

    private void appendMessages(ChatCompletionCreateParams.Builder params, List<ChatMessage> messages) {
        for (ChatMessage message : messages) {
            switch (message) {
                case ChatMessage.User user -> params.addUserMessage(user.text());

                case ChatMessage.Assistant assistant -> {
                    ChatCompletionAssistantMessageParam.Builder builder =
                            ChatCompletionAssistantMessageParam.builder();
                    if (assistant.text() != null && !assistant.text().isBlank()) {
                        builder.content(assistant.text());
                    }
                    for (ToolCall call : assistant.toolCalls()) {
                        // ChatCompletionMessageToolCall is a union (function |
                        // custom) in SDK 4.x, so the concrete function type is
                        // built and then wrapped rather than built directly.
                        builder.addToolCall(ChatCompletionMessageToolCall.ofFunction(
                                ChatCompletionMessageFunctionToolCall.builder()
                                        .id(call.id())
                                        .function(ChatCompletionMessageFunctionToolCall.Function.builder()
                                                .name(call.name())
                                                .arguments(writeArguments(call.arguments()))
                                                .build())
                                        .build()));
                    }
                    params.addMessage(builder.build());
                }

                // Fanned back out: one tool message per result. The neutral
                // type keeps them together because Anthropic requires that;
                // here they have to be separate, and the id on each is what
                // pairs them back up.
                case ChatMessage.ToolResults toolResults -> {
                    for (ToolResult result : toolResults.results()) {
                        // No is_error field on this API. Without the prefix a
                        // failure is indistinguishable from a successful call
                        // that happened to return the text of an error.
                        String content = result.isError()
                                ? "ERROR: " + result.content()
                                : result.content();
                        params.addMessage(com.openai.models.chat.completions
                                .ChatCompletionToolMessageParam.builder()
                                .toolCallId(result.toolCallId())
                                .content(content)
                                .build());
                    }
                }
            }
        }
    }

    private ChatCompletionTool toTool(ToolSpec spec) {
        FunctionParameters.Builder parameters = FunctionParameters.builder();
        spec.inputSchema().forEach((key, value) ->
                parameters.putAdditionalProperty(key, JsonValue.from(value)));

        return ChatCompletionTool.ofFunction(ChatCompletionFunctionTool.builder()
                .function(FunctionDefinition.builder()
                        .name(spec.name())
                        .description(spec.description())
                        .parameters(parameters.build())
                        .build())
                .build());
    }

    private String writeArguments(Map<String, Object> arguments) {
        try {
            return mapper.writeValueAsString(arguments);
        } catch (Exception ex) {
            log.warn("Could not serialise tool arguments; sending an empty object", ex);
            return "{}";
        }
    }

    // ---------------------------------------------------------- response ---

    private ChatResponse toChatResponse(ChatCompletion completion) {
        ChatCompletion.Choice choice = completion.choices().stream().findFirst().orElse(null);
        if (choice == null) {
            return new ChatResponse("", List.of(), ChatResponse.StopReason.OTHER, 0, 0);
        }

        String text = choice.message().content().orElse("");
        List<ToolCall> calls = new ArrayList<>();
        choice.message().toolCalls().ifPresent(list -> {
            for (ChatCompletionMessageToolCall call : list) {
                // Only the function arm is meaningful here. A custom-tool arm
                // is skipped rather than coerced: we never offer custom tools,
                // so one arriving means something we do not understand, and
                // inventing a ToolCall for it would send the dispatcher after
                // a target that was never on the allow-list.
                call.function().ifPresent(fn -> calls.add(new ToolCall(
                        fn.id(),
                        fn.function().name(),
                        readArguments(fn.function().arguments()))));
            }
        });

        long promptTokens = completion.usage().map(u -> u.promptTokens()).orElse(0L);
        long completionTokens = completion.usage().map(u -> u.completionTokens()).orElse(0L);

        return new ChatResponse(text, calls, stopReason(choice, calls),
                promptTokens, completionTokens);
    }

    private ChatResponse.StopReason stopReason(ChatCompletion.Choice choice, List<ToolCall> calls) {
        String reason = choice.finishReason().toString().toLowerCase();
        return switch (reason) {
            case "tool_calls", "function_call" -> ChatResponse.StopReason.TOOL_CALLS;
            case "stop" ->
                // Some OpenAI-compatible hosts report "stop" even when they
                // emitted tool calls. Trusting the label alone would end the
                // loop with the calls unexecuted and no error anywhere.
                    calls.isEmpty() ? ChatResponse.StopReason.END_TURN
                            : ChatResponse.StopReason.TOOL_CALLS;
            case "length" -> ChatResponse.StopReason.MAX_TOKENS;
            case "content_filter" -> ChatResponse.StopReason.REFUSAL;
            default -> ChatResponse.StopReason.OTHER;
        };
    }

    /**
     * Arguments arrive as a JSON string here, unlike Anthropic's structured
     * object. A model can emit malformed JSON; that is a tool-call failure to
     * report, not a run to crash, so it degrades to an empty map and the
     * dispatcher's own validation produces the error the model sees.
     */
    private Map<String, Object> readArguments(String json) {
        if (json == null || json.isBlank()) {
            return Map.of();
        }
        try {
            return mapper.readValue(json, MAP_TYPE);
        } catch (Exception ex) {
            log.warn("Model returned unparseable tool arguments: {}", ex.getMessage());
            return new LinkedHashMap<>();
        }
    }
}
