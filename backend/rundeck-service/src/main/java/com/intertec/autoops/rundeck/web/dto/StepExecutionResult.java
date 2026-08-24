package com.intertec.autoops.rundeck.web.dto;

/**
 * The outcome of one step, shaped to drop straight into core-service's
 * {@code StepExecutor.StepOutcome}.
 *
 * <p>{@code output} is the captured Rundeck log for this step and nothing else —
 * core-service appends it to the run log exactly as it appended job-service's
 * output, so run history reads identically across the swap.
 */
public record StepExecutionResult(

        boolean success,

        String output,

        String error,

        /**
         * Rundeck reports a per-node outcome rather than a single process exit
         * code, so this is a synthesised 0/1 for compatibility with the run
         * log's existing shape. The authoritative detail is in {@code output}.
         */
        Integer exitCode,

        long durationMs,

        /** Rundeck's execution id — the receipt an operator can correlate on. */
        Long executionId,

        /** Which Rundeck project it ran in; useful when diagnosing isolation. */
        String rundeckProject,

        /** Nodes that failed, when the step was dispatched across a filter. */
        java.util.List<String> failedNodes,

        java.util.List<String> succeededNodes) {

    public static StepExecutionResult failed(String error, long durationMs) {
        return new StepExecutionResult(false, null, error, 1, durationMs, null, null,
                java.util.List.of(), java.util.List.of());
    }
}
