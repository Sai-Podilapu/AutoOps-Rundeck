package com.intertec.autoops.agent.loop;

import com.google.genai.Client;
import com.google.genai.types.Candidate;
import com.google.genai.types.Content;
import com.google.genai.types.FunctionCall;
import com.google.genai.types.FunctionDeclaration;
import com.google.genai.types.GenerateContentConfig;
import com.google.genai.types.GenerateContentResponse;
import com.google.genai.types.Part;
import com.google.genai.types.Tool;
import com.intertec.autoops.agent.modelsdk.ModelVendor;
import com.intertec.autoops.agent.modelsdk.google.GoogleClientFactory;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Google Gemini.
 *
 * <p>The awkward part here is correlation. Every other vendor pairs a tool
 * call with its result by an opaque id; Gemini pairs them by FUNCTION NAME -
 * {@code Part.fromFunctionResponse} takes a name, and {@code FunctionCall.id()}
 * is optional and frequently absent.
 *
 * <p>Rather than leak that into the neutral types, this adapter keeps the id
 * contract and bridges it locally: when Gemini supplies no id the function
 * name is used as one, and on the way back the walk records id -> name so a
 * response can be addressed the way Gemini expects. The alternative - making
 * {@link ToolCall} carry both an id and a name for every vendor purely to suit
 * this one - would push the oddity onto four adapters that do not have it.
 *
 * <p>Gemini also has no error flag on a function response, so a failed tool
 * says so in its payload.
 */
@Component
public class GoogleChatModel implements ChatModel {

    @Override
    public boolean supports(ModelVendor vendor) {
        return vendor == ModelVendor.GOOGLE;
    }

    @Override
    public ChatResponse chat(Request request) {
        Client client = GoogleClientFactory.create(request.credentials());

        GenerateContentConfig.Builder config = GenerateContentConfig.builder()
                .maxOutputTokens(request.maxTokens());

        if (request.system() != null && !request.system().isBlank()) {
            config.systemInstruction(Content.fromParts(Part.fromText(request.system())));
        }
        if (!request.tools().isEmpty()) {
            config.tools(List.of(Tool.builder()
                    .functionDeclarations(request.tools().stream().map(this::toDeclaration).toList())
                    .build()));
        }

        GenerateContentResponse response = client.models.generateContent(
                request.model(), toContents(request.messages()), config.build());

        return toChatResponse(response);
    }

    // ----------------------------------------------------------- request ---

    private List<Content> toContents(List<ChatMessage> messages) {
        List<Content> out = new ArrayList<>();

        // Gemini addresses a function response by name, so the walk carries
        // the id -> name mapping forward from the assistant turn that made
        // the call to the result turn that answers it.
        Map<String, String> nameByCallId = new HashMap<>();

        for (ChatMessage message : messages) {
            switch (message) {
                case ChatMessage.User user -> out.add(Content.builder()
                        .role("user")
                        .parts(List.of(Part.fromText(user.text())))
                        .build());

                case ChatMessage.Assistant assistant -> {
                    List<Part> parts = new ArrayList<>();
                    if (assistant.text() != null && !assistant.text().isBlank()) {
                        parts.add(Part.fromText(assistant.text()));
                    }
                    for (ToolCall call : assistant.toolCalls()) {
                        nameByCallId.put(call.id(), call.name());
                        parts.add(Part.fromFunctionCall(call.name(), call.arguments()));
                    }
                    out.add(Content.builder().role("model").parts(parts).build());
                }

                case ChatMessage.ToolResults toolResults -> {
                    List<Part> parts = new ArrayList<>();
                    for (ToolResult result : toolResults.results()) {
                        // Falls back to the id itself, which IS the name when
                        // Gemini gave us no id to begin with.
                        String name = nameByCallId.getOrDefault(result.toolCallId(), result.toolCallId());

                        Map<String, Object> payload = new LinkedHashMap<>();
                        if (result.isError()) {
                            // No error flag on this API; without saying so the
                            // model reads a failure as a successful result.
                            payload.put("error", result.content());
                        } else {
                            payload.put("result", result.content());
                        }
                        parts.add(Part.fromFunctionResponse(name, payload));
                    }
                    out.add(Content.builder().role("user").parts(parts).build());
                }
            }
        }
        return out;
    }

    private FunctionDeclaration toDeclaration(ToolSpec spec) {
        return FunctionDeclaration.builder()
                .name(spec.name())
                .description(spec.description())
                // Takes the raw JSON Schema, so the neutral schema goes
                // through unchanged rather than being rebuilt as a Schema
                // object field by field.
                .parametersJsonSchema(spec.inputSchema())
                .build();
    }

    // ---------------------------------------------------------- response ---

    private ChatResponse toChatResponse(GenerateContentResponse response) {
        String text = "";
        try {
            text = response.text() == null ? "" : response.text();
        } catch (RuntimeException ex) {
            // text() throws when the candidate carries only function calls.
            // That is a normal tool-calling turn, not an error.
            text = "";
        }

        List<ToolCall> calls = new ArrayList<>();
        int index = 0;
        for (FunctionCall call : response.functionCalls()) {
            String name = call.name().orElse("unknown");
            String id = call.id().orElse(name);
            calls.add(new ToolCall(id, name, call.args().orElseGet(Map::of)));
            index++;
        }

        long promptTokens = response.usageMetadata()
                .flatMap(u -> u.promptTokenCount()).map(Integer::longValue).orElse(0L);
        long completionTokens = response.usageMetadata()
                .flatMap(u -> u.candidatesTokenCount()).map(Integer::longValue).orElse(0L);

        return new ChatResponse(text, calls, stopReason(response, calls),
                promptTokens, completionTokens);
    }

    private ChatResponse.StopReason stopReason(GenerateContentResponse response, List<ToolCall> calls) {
        if (!calls.isEmpty()) {
            // Gemini reports STOP on a turn that contains function calls, so
            // the presence of calls is the signal, not the finish reason.
            return ChatResponse.StopReason.TOOL_CALLS;
        }
        String reason = response.candidates()
                .flatMap(list -> list.stream().findFirst())
                .flatMap(Candidate::finishReason)
                .map(Object::toString)
                .orElse("")
                .toUpperCase();

        return switch (reason) {
            case "STOP" -> ChatResponse.StopReason.END_TURN;
            case "MAX_TOKENS" -> ChatResponse.StopReason.MAX_TOKENS;
            case "SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII" -> ChatResponse.StopReason.REFUSAL;
            default -> ChatResponse.StopReason.OTHER;
        };
    }
}
