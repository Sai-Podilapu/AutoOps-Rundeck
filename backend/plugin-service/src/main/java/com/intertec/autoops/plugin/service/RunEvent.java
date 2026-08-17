package com.intertec.autoops.plugin.service;

import com.intertec.autoops.plugin.domain.LifecycleEvent;
import com.intertec.autoops.plugin.domain.TargetType;

import java.time.Duration;
import java.time.Instant;

/**
 * One lifecycle moment as core-service reports it, before any rule has been
 * consulted.
 *
 * <p>{@code tenantId} arrives in the body rather than a header. The internal
 * token authenticates the caller as core-service; it does not choose a
 * workspace, so this field is what every rule lookup is filtered by and it
 * must always be the tenant that owns the run.
 */
public record RunEvent(
        String tenantId,
        TargetType targetType,
        Long targetId,
        String targetName,
        LifecycleEvent event,
        Long runId,
        Long projectId,
        String projectName,
        String triggeredBy,
        String detail,
        Instant occurredAt,
        Duration duration) {

    public RunEvent {
        if (occurredAt == null) {
            occurredAt = Instant.now();
        }
    }
}
