package com.intertec.autoops.agent.loop;

/**
 * What a tool returned, or the error it raised.
 *
 * <p>A failed tool produces a result with {@code isError} set - it is never
 * dropped. Dropping it leaves the model's {@code tool_use} block unanswered,
 * which every vendor rejects; and even where it did not, silently omitting the
 * failure means the model reasons on as though the call succeeded. Telling it
 * the truth is both the only legal option and the useful one: given the error,
 * models routinely correct the arguments and try again.
 */
public record ToolResult(String toolCallId, String content, boolean isError) {

    public static ToolResult ok(String toolCallId, String content) {
        return new ToolResult(toolCallId, content, false);
    }

    public static ToolResult error(String toolCallId, String message) {
        return new ToolResult(toolCallId, message, true);
    }
}
