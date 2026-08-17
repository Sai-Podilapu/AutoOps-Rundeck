package com.intertec.autoops.agent.loop;

import com.intertec.autoops.agent.modelsdk.ModelVendor;
import com.intertec.autoops.agent.modelsdk.bedrock.BedrockClientFactory;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.core.document.Document;
import software.amazon.awssdk.services.bedrockruntime.BedrockRuntimeClient;
import software.amazon.awssdk.services.bedrockruntime.model.ContentBlock;
import software.amazon.awssdk.services.bedrockruntime.model.ConversationRole;
import software.amazon.awssdk.services.bedrockruntime.model.ConverseRequest;
import software.amazon.awssdk.services.bedrockruntime.model.ConverseResponse;
import software.amazon.awssdk.services.bedrockruntime.model.InferenceConfiguration;
import software.amazon.awssdk.services.bedrockruntime.model.Message;
import software.amazon.awssdk.services.bedrockruntime.model.Tool;
import software.amazon.awssdk.services.bedrockruntime.model.ToolConfiguration;
import software.amazon.awssdk.services.bedrockruntime.model.ToolInputSchema;
import software.amazon.awssdk.services.bedrockruntime.model.ToolResultBlock;
import software.amazon.awssdk.services.bedrockruntime.model.ToolResultContentBlock;
import software.amazon.awssdk.services.bedrockruntime.model.ToolResultStatus;
import software.amazon.awssdk.services.bedrockruntime.model.ToolSpecification;
import software.amazon.awssdk.services.bedrockruntime.model.ToolUseBlock;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * AWS Bedrock, through the Converse API.
 *
 * <p>Converse rather than {@code InvokeModel}: InvokeModel takes each model
 * family's own raw request body, so tool calling there would mean a different
 * payload shape per family behind one vendor. Converse is the unified surface
 * and hands back structured {@code toolUse} blocks whatever the underlying
 * model is.
 *
 * <p>Bedrock's shape is closest to Anthropic's - tool results ride in a USER
 * message, all together - which is unsurprising given where Converse came
 * from. Unlike the OpenAI family it does have a first-class error signal on a
 * tool result ({@link ToolResultStatus#ERROR}), so failures do not need a text
 * prefix to be legible.
 *
 * <p>JSON here is {@link Document}, not a map or a string, so the schema and
 * the arguments are converted in both directions below.
 */
@Component
public class BedrockChatModel implements ChatModel {

    @Override
    public boolean supports(ModelVendor vendor) {
        return vendor == ModelVendor.BEDROCK;
    }

    @Override
    public ChatResponse chat(Request request) {
        BedrockRuntimeClient client = BedrockClientFactory.create(request.credentials());

        ConverseRequest.Builder converse = ConverseRequest.builder()
                .modelId(request.model())
                .messages(toMessages(request.messages()))
                .inferenceConfig(InferenceConfiguration.builder()
                        .maxTokens(request.maxTokens())
                        .build());

        if (request.system() != null && !request.system().isBlank()) {
            converse.system(software.amazon.awssdk.services.bedrockruntime.model.SystemContentBlock
                    .fromText(request.system()));
        }
        if (!request.tools().isEmpty()) {
            converse.toolConfig(ToolConfiguration.builder()
                    .tools(request.tools().stream().map(this::toTool).toList())
                    .build());
        }

        ConverseResponse response = client.converse(converse.build());
        return toChatResponse(response);
    }

    // ----------------------------------------------------------- request ---

    private List<Message> toMessages(List<ChatMessage> messages) {
        List<Message> out = new ArrayList<>();
        for (ChatMessage message : messages) {
            switch (message) {
                case ChatMessage.User user -> out.add(Message.builder()
                        .role(ConversationRole.USER)
                        .content(ContentBlock.fromText(user.text()))
                        .build());

                case ChatMessage.Assistant assistant -> {
                    List<ContentBlock> blocks = new ArrayList<>();
                    if (assistant.text() != null && !assistant.text().isBlank()) {
                        blocks.add(ContentBlock.fromText(assistant.text()));
                    }
                    for (ToolCall call : assistant.toolCalls()) {
                        blocks.add(ContentBlock.fromToolUse(ToolUseBlock.builder()
                                .toolUseId(call.id())
                                .name(call.name())
                                .input(toDocument(call.arguments()))
                                .build()));
                    }
                    out.add(Message.builder()
                            .role(ConversationRole.ASSISTANT)
                            .content(blocks)
                            .build());
                }

                // As on Anthropic: one user message carrying every result.
                case ChatMessage.ToolResults toolResults -> {
                    List<ContentBlock> blocks = new ArrayList<>();
                    for (ToolResult result : toolResults.results()) {
                        blocks.add(ContentBlock.fromToolResult(ToolResultBlock.builder()
                                .toolUseId(result.toolCallId())
                                .content(ToolResultContentBlock.fromText(result.content()))
                                .status(result.isError() ? ToolResultStatus.ERROR : ToolResultStatus.SUCCESS)
                                .build()));
                    }
                    out.add(Message.builder()
                            .role(ConversationRole.USER)
                            .content(blocks)
                            .build());
                }
            }
        }
        return out;
    }

    private Tool toTool(ToolSpec spec) {
        return Tool.fromToolSpec(ToolSpecification.builder()
                .name(spec.name())
                .description(spec.description())
                .inputSchema(ToolInputSchema.fromJson(toDocument(spec.inputSchema())))
                .build());
    }

    // ---------------------------------------------------------- response ---

    private ChatResponse toChatResponse(ConverseResponse response) {
        StringBuilder text = new StringBuilder();
        List<ToolCall> calls = new ArrayList<>();

        if (response.output() != null && response.output().message() != null) {
            for (ContentBlock block : response.output().message().content()) {
                if (block.text() != null) {
                    if (!text.isEmpty()) {
                        text.append('\n');
                    }
                    text.append(block.text());
                }
                if (block.toolUse() != null) {
                    ToolUseBlock use = block.toolUse();
                    calls.add(new ToolCall(use.toolUseId(), use.name(), fromDocument(use.input())));
                }
            }
        }

        long promptTokens = response.usage() == null ? 0 : response.usage().inputTokens();
        long completionTokens = response.usage() == null ? 0 : response.usage().outputTokens();

        return new ChatResponse(text.toString(), calls, stopReason(response),
                promptTokens, completionTokens);
    }

    private ChatResponse.StopReason stopReason(ConverseResponse response) {
        String reason = response.stopReasonAsString() == null
                ? "" : response.stopReasonAsString().toLowerCase();
        return switch (reason) {
            case "tool_use" -> ChatResponse.StopReason.TOOL_CALLS;
            case "end_turn", "stop_sequence" -> ChatResponse.StopReason.END_TURN;
            case "max_tokens" -> ChatResponse.StopReason.MAX_TOKENS;
            case "content_filtered", "guardrail_intervened" -> ChatResponse.StopReason.REFUSAL;
            default -> ChatResponse.StopReason.OTHER;
        };
    }

    // ------------------------------------------------------ JSON <-> doc ---

    @SuppressWarnings("unchecked")
    private Document toDocument(Object value) {
        if (value == null) {
            return Document.fromNull();
        }
        if (value instanceof Map<?, ?> map) {
            Map<String, Document> fields = new LinkedHashMap<>();
            map.forEach((key, item) -> fields.put(String.valueOf(key), toDocument(item)));
            return Document.fromMap(fields);
        }
        if (value instanceof List<?> list) {
            return Document.fromList(list.stream().map(this::toDocument).toList());
        }
        if (value instanceof Boolean bool) {
            return Document.fromBoolean(bool);
        }
        if (value instanceof Integer i) {
            return Document.fromNumber(i);
        }
        if (value instanceof Long l) {
            return Document.fromNumber(l);
        }
        if (value instanceof Number number) {
            return Document.fromNumber(number.doubleValue());
        }
        return Document.fromString(String.valueOf(value));
    }

    private Map<String, Object> fromDocument(Document document) {
        if (document == null || !document.isMap()) {
            return Map.of();
        }
        Map<String, Object> out = new LinkedHashMap<>();
        document.asMap().forEach((key, value) -> out.put(key, unwrap(value)));
        return out;
    }

    private Object unwrap(Document document) {
        if (document == null || document.isNull()) {
            return null;
        }
        if (document.isMap()) {
            return fromDocument(document);
        }
        if (document.isList()) {
            return document.asList().stream().map(this::unwrap).toList();
        }
        if (document.isBoolean()) {
            return document.asBoolean();
        }
        if (document.isNumber()) {
            return document.asNumber().doubleValue();
        }
        return document.asString();
    }
}
