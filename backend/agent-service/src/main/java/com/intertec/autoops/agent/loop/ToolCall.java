package com.intertec.autoops.agent.loop;

import java.util.Map;

/**
 * A tool the model asked to run.
 *
 * <p>{@code id} is the vendor's correlation id and is echoed back verbatim on
 * the matching {@link ToolResult}. It is not ours to generate or normalise:
 * Anthropic rejects a turn where any {@code tool_use} block lacks a
 * {@code tool_result} carrying its exact id, and OpenAI behaves the same way.
 *
 * <p>{@code arguments} is a parsed map, never the raw JSON string. Vendors
 * differ in how they escape Unicode and forward slashes inside tool arguments,
 * so anything that string-matches the serialised form breaks on a model
 * update; parsing once here means nothing downstream is tempted to.
 */
public record ToolCall(String id, String name, Map<String, Object> arguments) {

    public ToolCall {
        arguments = arguments == null ? Map.of() : Map.copyOf(arguments);
    }

    /** Reads an argument as a string, or null when absent. */
    public String argument(String key) {
        Object value = arguments.get(key);
        return value == null ? null : String.valueOf(value);
    }

    /** Reads an argument as a long, or null when absent or not a number. */
    public Long longArgument(String key) {
        Object value = arguments.get(key);
        if (value instanceof Number number) {
            return number.longValue();
        }
        if (value == null) {
            return null;
        }
        try {
            return Long.parseLong(String.valueOf(value).trim());
        } catch (NumberFormatException ex) {
            return null;
        }
    }
}
