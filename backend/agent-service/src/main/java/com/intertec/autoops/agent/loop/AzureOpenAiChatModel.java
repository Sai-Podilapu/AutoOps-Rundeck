package com.intertec.autoops.agent.loop;

import com.azure.ai.openai.OpenAIClient;
import com.azure.ai.openai.models.ChatChoice;
import com.azure.ai.openai.models.ChatCompletions;
import com.azure.ai.openai.models.ChatCompletionsFunctionToolCall;
import com.azure.ai.openai.models.ChatCompletionsFunctionToolDefinition;
import com.azure.ai.openai.models.ChatCompletionsFunctionToolDefinitionFunction;
import com.azure.ai.openai.models.ChatCompletionsOptions;
import com.azure.ai.openai.models.ChatCompletionsToolCall;
import com.azure.ai.openai.models.ChatCompletionsToolDefinition;
import com.azure.ai.openai.models.ChatRequestAssistantMessage;
import com.azure.ai.openai.models.ChatRequestMessage;
import com.azure.ai.openai.models.ChatRequestSystemMessage;
import com.azure.ai.openai.models.ChatRequestToolMessage;
import com.azure.ai.openai.models.ChatRequestUserMessage;
import com.azure.core.util.BinaryData;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.agent.modelsdk.ModelVendor;
import com.intertec.autoops.agent.modelsdk.azure.AzureOpenAiClientFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Azure OpenAI.
 *
 * <p>Shares OpenAI's semantics but not its SDK, and one difference bites
 * immediately: Azure routes on a DEPLOYMENT NAME, not a model name. The
 * agent's {@code model} field therefore carries the deployment for this
 * vendor - putting {@code gpt-4o} there when the deployment is called
 * {@code prod-gpt4o} produces a 404 that reads like the model does not exist.
 */
@Component
public class AzureOpenAiChatModel implements ChatModel {

    private static final Logger log = LoggerFactory.getLogger(AzureOpenAiChatModel.class);
    private static final TypeReference<Map<String, Object>> MAP_TYPE = new TypeReference<>() { };

    private final ObjectMapper mapper;

    public AzureOpenAiChatModel(ObjectMapper mapper) {
        this.mapper = mapper;
    }

    @Override
    public boolean supports(ModelVendor vendor) {
        return vendor == ModelVendor.AZURE_OPENAI;
    }

    @Override
    public ChatResponse chat(Request request) {
        OpenAIClient client = AzureOpenAiClientFactory.create(request.credentials());

        List<ChatRequestMessage> messages = new ArrayList<>();
        if (request.system() != null && !request.system().isBlank()) {
            messages.add(new ChatRequestSystemMessage(request.system()));
        }
        appendMessages(messages, request.messages());

        ChatCompletionsOptions options = new ChatCompletionsOptions(messages);
        options.setMaxTokens(request.maxTokens());
        if (!request.tools().isEmpty()) {
            options.setTools(request.tools().stream().map(this::toTool).toList());
        }

        // The deployment name, not the model name.
        ChatCompletions completions = client.getChatCompletions(request.model(), options);
        return toChatResponse(completions);
    }

    // ----------------------------------------------------------- request ---

    private void appendMessages(List<ChatRequestMessage> out, List<ChatMessage> messages) {
        for (ChatMessage message : messages) {
            switch (message) {
                case ChatMessage.User user -> out.add(new ChatRequestUserMessage(user.text()));

                case ChatMessage.Assistant assistant -> {
                    ChatRequestAssistantMessage msg =
                            new ChatRequestAssistantMessage(assistant.text() == null ? "" : assistant.text());
                    if (!assistant.toolCalls().isEmpty()) {
                        List<ChatCompletionsToolCall> calls = new ArrayList<>();
                        for (ToolCall call : assistant.toolCalls()) {
                            calls.add(new ChatCompletionsFunctionToolCall(call.id(),
                                    new com.azure.ai.openai.models.FunctionCall(
                                            call.name(), writeArguments(call.arguments()))));
                        }
                        msg.setToolCalls(calls);
                    }
                    out.add(msg);
                }

                // One tool message per result, as on OpenAI. No is_error field
                // here either, so a failure has to announce itself in content.
                case ChatMessage.ToolResults toolResults -> {
                    for (ToolResult result : toolResults.results()) {
                        String content = result.isError()
                                ? "ERROR: " + result.content()
                                : result.content();
                        out.add(new ChatRequestToolMessage(content, result.toolCallId()));
                    }
                }
            }
        }
    }

    private ChatCompletionsToolDefinition toTool(ToolSpec spec) {
        ChatCompletionsFunctionToolDefinitionFunction function =
                new ChatCompletionsFunctionToolDefinitionFunction(spec.name());
        function.setDescription(spec.description());
        function.setParameters(BinaryData.fromObject(spec.inputSchema()));
        return new ChatCompletionsFunctionToolDefinition(function);
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

    private ChatResponse toChatResponse(ChatCompletions completions) {
        ChatChoice choice = completions.getChoices().isEmpty() ? null : completions.getChoices().get(0);
        if (choice == null) {
            return new ChatResponse("", List.of(), ChatResponse.StopReason.OTHER, 0, 0);
        }

        String text = choice.getMessage().getContent() == null ? "" : choice.getMessage().getContent();
        List<ToolCall> calls = new ArrayList<>();
        if (choice.getMessage().getToolCalls() != null) {
            for (ChatCompletionsToolCall call : choice.getMessage().getToolCalls()) {
                if (call instanceof ChatCompletionsFunctionToolCall fn) {
                    calls.add(new ToolCall(fn.getId(), fn.getFunction().getName(),
                            readArguments(fn.getFunction().getArguments())));
                }
            }
        }

        long promptTokens = completions.getUsage() == null ? 0 : completions.getUsage().getPromptTokens();
        long completionTokens = completions.getUsage() == null ? 0 : completions.getUsage().getCompletionTokens();

        return new ChatResponse(text, calls, stopReason(choice, calls), promptTokens, completionTokens);
    }

    private ChatResponse.StopReason stopReason(ChatChoice choice, List<ToolCall> calls) {
        String reason = choice.getFinishReason() == null ? "" : choice.getFinishReason().toString().toLowerCase();
        return switch (reason) {
            case "tool_calls", "function_call" -> ChatResponse.StopReason.TOOL_CALLS;
            // Same defensive read as the OpenAI adapter: some deployments
            // report "stop" while still emitting tool calls, and believing the
            // label would end the run with those calls silently unexecuted.
            case "stop" -> calls.isEmpty() ? ChatResponse.StopReason.END_TURN
                    : ChatResponse.StopReason.TOOL_CALLS;
            case "length" -> ChatResponse.StopReason.MAX_TOKENS;
            case "content_filter" -> ChatResponse.StopReason.REFUSAL;
            default -> ChatResponse.StopReason.OTHER;
        };
    }

    private Map<String, Object> readArguments(String json) {
        if (json == null || json.isBlank()) {
            return Map.of();
        }
        try {
            return mapper.readValue(json, MAP_TYPE);
        } catch (Exception ex) {
            log.warn("Model returned unparseable tool arguments: {}", ex.getMessage());
            return Map.of();
        }
    }
}
