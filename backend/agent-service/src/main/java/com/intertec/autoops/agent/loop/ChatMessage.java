package com.intertec.autoops.agent.loop;

import java.util.List;

/**
 * One turn of an agent conversation, in a shape no vendor uses.
 *
 * <p>The vendors disagree about how a tool exchange is represented. Anthropic
 * puts {@code tool_use} blocks inside the assistant message and sends every
 * {@code tool_result} back in a SINGLE user message. OpenAI puts
 * {@code tool_calls} on the assistant message and sends each result back as
 * its own message with role {@code tool}. Modelling either shape here would
 * make the other adapter a translation of a translation, so this models
 * neither: three cases, each of which every adapter knows how to emit.
 *
 * <p>{@link ToolResults} is deliberately a LIST rather than one result per
 * message. Anthropic's API requires all results for a turn in one message -
 * splitting them trains the model to stop requesting parallel tool calls - and
 * a shape that can only express one at a time would make that impossible to
 * get right. The OpenAI adapter fans the list back out; the reverse is lossy.
 */
public sealed interface ChatMessage {

    /** What the human asked for. */
    record User(String text) implements ChatMessage { }

    /**
     * What the model said, and what it wants to run.
     *
     * <p>Both fields can be populated at once: models routinely narrate before
     * calling a tool, and dropping that text loses the only explanation the
     * run record will ever have for why the tool was called.
     */
    record Assistant(String text, List<ToolCall> toolCalls) implements ChatMessage {
        public Assistant {
            toolCalls = toolCalls == null ? List.of() : List.copyOf(toolCalls);
        }
    }

    /** Every result for one assistant turn, together. */
    record ToolResults(List<ToolResult> results) implements ChatMessage {
        public ToolResults {
            results = List.copyOf(results);
        }
    }
}
