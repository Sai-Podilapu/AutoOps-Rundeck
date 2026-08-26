package com.intertec.autoops.rundeck.web.dto;

/**
 * One AutoOps job, handed over to be created or updated on the engine.
 *
 * <p>Carries the job's DEFINITION rather than a reference to it: rundeck-service
 * has no access to core-service's schema and must not grow one. The definition
 * is read, translated and imported — never stored here.
 */
public record JobSyncRequest(

        String tenantId,

        /** Scopes the Rundeck project the job is imported into. */
        Long projectId,

        /** autoops_core.jobs.id — the seed for the derived Rundeck job UUID. */
        Long jobId,

        String name,

        String description,

        /** The job's steps: {@code {"steps":[...]}}. */
        String definition,

        /** Standard 5-field Unix cron, or null when the job is not scheduled. */
        String schedule,

        String scheduleTimezone,

        Boolean enabled,

        /**
         * When true the engine records the schedule but never fires it — Rundeck
         * cannot pause to ask a human, so AutoOps keeps the cron and triggers
         * the job only once the approval is granted.
         */
        Boolean requiresApproval) {
}
