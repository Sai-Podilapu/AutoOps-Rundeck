package com.intertec.autoops.agent.loop;

import com.anthropic.client.AnthropicClient;
import com.anthropic.core.JsonValue;
import com.anthropic.models.messages.ContentBlock;
import com.anthropic.models.messages.ContentBlockParam;
import com.anthropic.models.messages.Message;
import com.anthropic.models.messages.MessageCreateParams;
import com.anthropic.models.messages.MessageParam;
import com.anthropic.models.messages.TextBlockParam;
import com.anthropic.models.messages.Tool;
import com.anthropic.models.messages.ToolResultBlockParam;
import com.anthropic.models.messages.ToolUseBlockParam;
import com.intertec.autoops.agent.modelsdk.ModelCredentials;
import com.intertec.autoops.agent.modelsdk.ModelVendor;
import com.intertec.autoops.agent.modelsdk.claude.ClaudeClientFactory;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Anthropic, through its own Java SDK.
 *
 * <p>Three details of this API are easy to get wrong and expensive when you
 * do, so they are called out where they happen below:
 *
 * <ol>
 *   <li>the assistant turn must be echoed back with its {@code tool_use}
 *       blocks intact, not just its text;</li>
 *   <li>every {@code tool_use} block needs a {@code tool_result} carrying its
 *       exact id, and all of them belong in ONE user message;</li>
 *   <li>{@code stop_reason} decides whether the loop continues - reading
 *       {@code content} first and inferring from it does not survive a refusal
 *       or a truncation.</li>
 * </ol>
 */
@Component
public class AnthropicChatModel implements ChatModel {

    @Override
    public boolean supports(ModelVendor vendor) {
        return vendor == ModelVendor.ANTHROPIC;
    }

    @Override
    public ChatResponse chat(Request request) {
        AnthropicClient client = ClaudeClientFactory.create(request.credentials());

        MessageCreateParams.Builder params = MessageCreateParams.builder()
                .model(request.model())
                .maxTokens(request.maxTokens());

        if (request.system() != null && !request.system().isBlank()) {
            params.system(request.system());
        }
        for (ToolSpec spec : request.tools()) {
            params.addTool(toTool(spec));
        }
        for (MessageParam message : toMessageParams(request.messages())) {
            params.addMessage(message);
        }

        Message response = client.messages().create(params.build());
        return toChatResponse(response);
    }

    // ----------------------------------------------------------- request ---

    private List<MessageParam> toMessageParams(List<ChatMessage> messages) {
        List<MessageParam> out = new ArrayList<>();
        for (ChatMessage message : messages) {
            switch (message) {
                case ChatMessage.User user -> out.add(MessageParam.builder()
                        .role(MessageParam.Role.USER)
                        .content(user.text())
                        .build());

                // The assistant turn is echoed back with its tool_use blocks
                // rebuilt, not as bare text. Sending only the text would leave
                // the following tool_result blocks referring to ids the API
                // can no longer see, and it rejects the turn.
                case ChatMessage.Assistant assistant -> {
                    List<ContentBlockParam> blocks = new ArrayList<>();
                    if (assistant.text() != null && !assistant.text().isBlank()) {
                        blocks.add(ContentBlockParam.ofText(
                                TextBlockParam.builder().text(assistant.text()).build()));
                    }
                    for (ToolCall call : assistant.toolCalls()) {
                        blocks.add(ContentBlockParam.ofToolUse(ToolUseBlockParam.builder()
                                .id(call.id())
                                .name(call.name())
                                .input(JsonValue.from(call.arguments()))
                                .build()));
                    }
                    out.add(MessageParam.builder()
                            .role(MessageParam.Role.ASSISTANT)
                            .contentOfBlockParams(blocks)
                            .build());
                }

                // Every result for the turn in ONE user message. Splitting
                // them across several messages is accepted by the API but
                // teaches the model to stop asking for tools in parallel,
                // which shows up later as a slow agent nobody can explain.
                case ChatMessage.ToolResults toolResults -> {
                    List<ContentBlockParam> blocks = new ArrayList<>();
                    for (ToolResult result : toolResults.results()) {
                        blocks.add(ContentBlockParam.ofToolResult(ToolResultBlockParam.builder()
                                .toolUseId(result.toolCallId())
                                .content(result.content())
                                .isError(result.isError())
                                .build()));
                    }
                    out.add(MessageParam.builder()
                            .role(MessageParam.Role.USER)
                            .contentOfBlockParams(blocks)
                            .build());
                }
            }
        }
        return out;
    }

    private Tool toTool(ToolSpec spec) {
        Tool.InputSchema.Builder schema = Tool.InputSchema.builder();

        Object properties = spec.inputSchema().get("properties");
        if (properties instanceof Map<?, ?> map) {
            Tool.InputSchema.Properties.Builder props = Tool.InputSchema.Properties.builder();
            map.forEach((key, value) -> props.putAdditionalProperty(
                    String.valueOf(key), JsonValue.from(value)));
            schema.properties(props.build());
        }
        Object required = spec.inputSchema().get("required");
        if (required instanceof List<?> list) {
            schema.required(list.stream().map(String::valueOf).toList());
        }
        // Carried through so the model cannot invent fields the dispatcher
        // would then ignore without telling it.
        schema.putAdditionalProperty("additionalProperties", JsonValue.from(false));

        return Tool.builder()
                .name(spec.name())
                .description(spec.description())
                .inputSchema(schema.build())
                .build();
    }

    // ---------------------------------------------------------- response ---

    private ChatResponse toChatResponse(Message response) {
        StringBuilder text = new StringBuilder();
        List<ToolCall> calls = new ArrayList<>();

        for (ContentBlock block : response.content()) {
            block.text().ifPresent(t -> {
                if (!text.isEmpty()) {
                    text.append('\n');
                }
                text.append(t.text());
            });
            block.toolUse().ifPresent(use -> calls.add(new ToolCall(
                    use.id(), use.name(), asMap(use._input()))));
        }

        long promptTokens = response.usage().inputTokens();
        long completionTokens = response.usage().outputTokens();

        return new ChatResponse(text.toString(), calls,
                stopReason(response), promptTokens, completionTokens);
    }

    /**
     * The termination contract. Read from stop_reason rather than inferred
     * from the content: a refusal and a truncation both arrive as a normal
     * 200 with plausible-looking content, and only this field distinguishes
     * them from a finished answer.
     */
    private ChatResponse.StopReason stopReason(Message response) {
        String reason = response.stopReason().map(Object::toString).orElse("");
        return switch (reason.toLowerCase()) {
            case "tool_use" -> ChatResponse.StopReason.TOOL_CALLS;
            case "end_turn", "stop_sequence" -> ChatResponse.StopReason.END_TURN;
            case "max_tokens" -> ChatResponse.StopReason.MAX_TOKENS;
            case "refusal" -> ChatResponse.StopReason.REFUSAL;
            default -> ChatResponse.StopReason.OTHER;
        };
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> asMap(JsonValue input) {
        Object raw = input.asObject().orElse(null);
        if (raw instanceof Map<?, ?> map) {
            Map<String, Object> out = new LinkedHashMap<>();
            map.forEach((key, value) -> out.put(String.valueOf(key), unwrap(value)));
            return out;
        }
        return Map.of();
    }

    private Object unwrap(Object value) {
        if (value instanceof JsonValue json) {
            return json.asObject().map(Object.class::cast)
                    .or(() -> json.asString().map(Object.class::cast))
                    .or(() -> json.asNumber().map(Object.class::cast))
                    .or(() -> json.asBoolean().map(Object.class::cast))
                    .orElse(null);
        }
        return value;
    }
}
