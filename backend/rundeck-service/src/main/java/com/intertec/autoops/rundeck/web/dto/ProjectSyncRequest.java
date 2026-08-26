package com.intertec.autoops.rundeck.web.dto;

/**
 * A project lifecycle event from core-service: created, renamed, archived or
 * restored.
 *
 * <p>{@code label} and {@code description} are what the TENANT sees in AutoOps.
 * They are carried here only to be written onto the engine's copy as display
 * metadata — they never become the Rundeck project's {@code name}, which stays
 * derived and sanitized. See {@code ProjectProvisioner#syncMetadata}.
 */
public record ProjectSyncRequest(

        String tenantId,

        Long projectId,

        /** The AutoOps project name, shown in Rundeck as {@code project.label}. */
        String label,

        String description) {
}
