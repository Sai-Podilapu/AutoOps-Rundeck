package com.intertec.autoops.rundeck.web.dto;

import java.util.Map;

/**
 * One AutoOps step, handed over for execution.
 *
 * <p>Deliberately the same shape job-service's {@code /internal/execute} took,
 * field for field where it can be — core-service's run engine is unchanged and
 * should not be able to tell which runtime is behind the seam. What is new is
 * {@code nodeFilter}: the one capability Rundeck brings that job-service never
 * had.
 *
 * <p>{@code credentials} arrives DECRYPTED. core-service resolves the step's
 * cloud integration, decrypts it for this single call, and never persists it —
 * the same contract job-service had. Nothing here writes it to a database.
 */
public record StepExecutionRequest(

        String tenantId,

        /** Scopes the Rundeck project this runs in. Required — see ProjectProvisioner. */
        Long projectId,

        /** The AutoOps run this step belongs to; recorded on the dispatch receipt. */
        Long runId,

        Integer stepIndex,

        /** command | agent | script | pyscript | ssh | rest | terraform | kubernetes | awslambda | azurefn | test */
        String stepType,

        String label,

        /** The step body: a command line, a script, HCL, kubectl args, ... */
        String value,

        /**
         * The whole step node from the run's definition snapshot, for the
         * fields only some types use — {@code action} on terraform,
         * {@code region}/{@code qualifier} on awslambda, and so on. Passed
         * through rather than enumerated so a new optional field on a step type
         * does not need a change on both sides of the wire.
         */
        Map<String, Object> raw,

        Integer timeoutSeconds,

        /** Decrypted, single-use, never stored. */
        Map<String, String> credentials,

        /**
         * Rundeck node-filter syntax ({@code tags: web+prod}). Null runs on the
         * Rundeck server itself, which is what every job-service step did — so
         * an unmigrated job behaves exactly as it did before.
         */
        String nodeFilter,

        Integer nodeThreadcount,

        Boolean nodeKeepgoing) {
}
