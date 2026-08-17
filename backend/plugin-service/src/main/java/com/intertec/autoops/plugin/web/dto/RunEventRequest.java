package com.intertec.autoops.plugin.web.dto;

import com.intertec.autoops.plugin.domain.LifecycleEvent;
import com.intertec.autoops.plugin.domain.TargetType;
import com.intertec.autoops.plugin.service.RunEvent;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.time.Duration;
import java.time.Instant;

/**
 * The body core-service posts to {@code /internal/events}.
 *
 * <p>{@code tenantId} is required and is the only thing that scopes the
 * fan-out. The internal token proves the caller is core-service; it says
 * nothing about which workspace the run belonged to, so this field has to be
 * right and has to be present.
 */
public record RunEventRequest(
        @NotBlank(message = "is required")
        String tenantId,

        @NotNull(message = "is required")
        TargetType targetType,

        @NotNull(message = "is required")
        Long targetId,

        @NotBlank(message = "is required")
        String targetName,

        @NotNull(message = "is required")
        LifecycleEvent event,

        /** Null for MISSED — nothing ran, so there is no run row. */
        Long runId,

        Long projectId,
        String projectName,
        String triggeredBy,

        /** Error text for FAILED, the schedule for MISSED. */
        String detail,

        /** Defaults to now when core-service does not stamp it. */
        Instant occurredAt,

        Long durationSeconds) {

    public RunEvent toEvent() {
        return new RunEvent(
                tenantId,
                targetType,
                targetId,
                targetName,
                event,
                runId,
                projectId,
                projectName,
                triggeredBy,
                detail,
                occurredAt,
                durationSeconds == null ? null : Duration.ofSeconds(durationSeconds));
    }
}
