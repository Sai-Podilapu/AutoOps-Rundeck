package com.intertec.autoops.agent.loop;

import java.util.List;

/**
 * One model reply, normalised.
 *
 * <p>{@link StopReason} is the loop's termination contract, and it is the
 * reason this type exists rather than passing vendor responses around. The
 * loop continues only on {@link StopReason#TOOL_CALLS}; every other value ends
 * it, and they end it for materially different reasons that a caller has to be
 * able to tell apart.
 */
public record ChatResponse(String text,
                           List<ToolCall> toolCalls,
                           StopReason stopReason,
                           long promptTokens,
                           long completionTokens) {

    public ChatResponse {
        toolCalls = toolCalls == null ? List.of() : List.copyOf(toolCalls);
    }

    public boolean wantsTools() {
        return stopReason == StopReason.TOOL_CALLS && !toolCalls.isEmpty();
    }

    public enum StopReason {

        /** The model asked for tools. The ONLY value that continues the loop. */
        TOOL_CALLS,

        /** The model finished. This is success. */
        END_TURN,

        /**
         * The reply hit the output ceiling and is truncated mid-thought.
         * Reported as a failure rather than an answer: a half-written response
         * that looks complete is worse than an error.
         */
        MAX_TOKENS,

        /**
         * The vendor's safety classifiers declined. Not an exception - it
         * arrives as a successful HTTP response - so it has to be checked
         * before the text is read, or the run reports an empty answer as
         * though the model had nothing to say.
         */
        REFUSAL,

        /** Anything else the vendor reported, preserved rather than guessed at. */
        OTHER
    }
}
