package com.intertec.autoops.core.execution;

import com.fasterxml.jackson.databind.JsonNode;

/**
 * The seam between the run engine and whatever actually performs a step —
 * the same pattern as the subscription-service's PaymentProvider. Today the
 * only implementation is {@link SimulatedStepExecutor}; real cloud executors
 * (AWS/Azure/... via the tenant's cloud connections) plug in here later
 * without touching the engine.
 */
public interface StepExecutor {

    /**
     * One step/node to execute, parsed from the run's definition snapshot.
     * {@code attempt} is 0 on the first try and increments on retries.
     */
    record RunStep(int index, int total, String type, String label, JsonNode raw, int attempt) {

        RunStep withAttempt(int nextAttempt) {
            return new RunStep(index, total, type, label, raw, nextAttempt);
        }
    }

    /** detail (e.g. captured output) lands in the run log; error only on failure. */
    record StepOutcome(boolean success, String detail, String error, long durationMs) {

        public static StepOutcome ok(String detail, long durationMs) {
            return new StepOutcome(true, detail, null, durationMs);
        }

        public static StepOutcome failed(String error, long durationMs) {
            return new StepOutcome(false, null, error, durationMs);
        }

        /** Failure that still captured output (exit code != 0 after printing). */
        public static StepOutcome failed(String error, String detail, long durationMs) {
            return new StepOutcome(false, detail, error, durationMs);
        }
    }

    /**
     * @param projectId the project the step runs in, or null when there is no
     *                  project context (ad-hoc commands). It bounds which
     *                  cloud integrations the step may use — a connection
     *                  dedicated to another project is not reachable from here.
     */
    StepOutcome execute(String tenantId, Long projectId, RunStep step);
}