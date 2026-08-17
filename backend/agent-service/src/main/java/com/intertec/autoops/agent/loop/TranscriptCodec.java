package com.intertec.autoops.agent.loop;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.agent.exception.AgentException;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The message history, to and from the {@code transcript} column.
 *
 * <p>Written by hand rather than with Jackson polymorphism. {@link ChatMessage}
 * is a sealed interface of records, and the annotation-driven alternative would
 * bind the on-disk format to the Java type names: renaming a record, or moving
 * one, would make every parked run unresumable with no warning at compile time.
 * A run can sit in AWAITING_APPROVAL for days, so that format is a compatibility
 * surface and it gets an explicit, readable {@code role} discriminator.
 *
 * <p>A transcript that cannot be read is an error, never a silent empty
 * history. Resuming a conversation with the middle missing would have the model
 * re-run tools it has already run.
 */
@Component
public class TranscriptCodec {

    private static final TypeReference<List<Map<String, Object>>> ROWS = new TypeReference<>() { };

    private final ObjectMapper mapper;

    public TranscriptCodec(ObjectMapper mapper) {
        this.mapper = mapper;
    }

    public String write(List<ChatMessage> messages) {
        List<Map<String, Object>> rows = new ArrayList<>();
        for (ChatMessage message : messages) {
            switch (message) {
                case ChatMessage.User user -> rows.add(row("user", Map.of("text", nz(user.text()))));

                case ChatMessage.Assistant assistant -> {
                    List<Map<String, Object>> calls = new ArrayList<>();
                    for (ToolCall call : assistant.toolCalls()) {
                        calls.add(Map.of("id", call.id(), "name", call.name(),
                                "arguments", call.arguments()));
                    }
                    rows.add(row("assistant", Map.of(
                            "text", nz(assistant.text()),
                            "toolCalls", calls)));
                }

                case ChatMessage.ToolResults results -> {
                    List<Map<String, Object>> items = new ArrayList<>();
                    for (ToolResult result : results.results()) {
                        items.add(Map.of("toolCallId", result.toolCallId(),
                                "content", nz(result.content()),
                                "isError", result.isError()));
                    }
                    rows.add(row("toolResults", Map.of("results", items)));
                }
            }
        }
        try {
            return mapper.writeValueAsString(rows);
        } catch (Exception ex) {
            throw AgentException.internal("transcript_unwritable",
                    "The run's conversation could not be saved: " + ex.getMessage());
        }
    }

    @SuppressWarnings("unchecked")
    public List<ChatMessage> read(String json) {
        if (json == null || json.isBlank()) {
            return new ArrayList<>();
        }
        List<Map<String, Object>> rows;
        try {
            rows = mapper.readValue(json, ROWS);
        } catch (Exception ex) {
            throw AgentException.internal("transcript_unreadable",
                    "The run's saved conversation could not be read, so it cannot be "
                            + "resumed safely: " + ex.getMessage());
        }

        List<ChatMessage> messages = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            String role = String.valueOf(row.get("role"));
            switch (role) {
                case "user" -> messages.add(new ChatMessage.User(str(row.get("text"))));

                case "assistant" -> {
                    List<ToolCall> calls = new ArrayList<>();
                    if (row.get("toolCalls") instanceof List<?> list) {
                        for (Object item : list) {
                            if (item instanceof Map<?, ?> map) {
                                Map<String, Object> call = (Map<String, Object>) map;
                                Map<String, Object> arguments =
                                        call.get("arguments") instanceof Map<?, ?> args
                                                ? new LinkedHashMap<>((Map<String, Object>) args)
                                                : Map.of();
                                calls.add(new ToolCall(str(call.get("id")), str(call.get("name")),
                                        arguments));
                            }
                        }
                    }
                    messages.add(new ChatMessage.Assistant(str(row.get("text")), calls));
                }

                case "toolResults" -> {
                    List<ToolResult> results = new ArrayList<>();
                    if (row.get("results") instanceof List<?> list) {
                        for (Object item : list) {
                            if (item instanceof Map<?, ?> map) {
                                Map<String, Object> result = (Map<String, Object>) map;
                                results.add(new ToolResult(str(result.get("toolCallId")),
                                        str(result.get("content")),
                                        Boolean.TRUE.equals(result.get("isError"))));
                            }
                        }
                    }
                    messages.add(new ChatMessage.ToolResults(results));
                }

                default -> throw AgentException.internal("transcript_unreadable",
                        "The run's saved conversation contains an unknown entry \"" + role
                                + "\", so it cannot be resumed safely.");
            }
        }
        return messages;
    }

    private static Map<String, Object> row(String role, Map<String, Object> fields) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("role", role);
        out.putAll(fields);
        return out;
    }

    private static String nz(String value) {
        return value == null ? "" : value;
    }

    private static String str(Object value) {
        return value == null ? "" : String.valueOf(value);
    }
}
