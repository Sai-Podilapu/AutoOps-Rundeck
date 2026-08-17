package com.intertec.autoops.core.web.dto;

import com.intertec.autoops.core.domain.Run;

import java.time.Instant;

/**
 * {@code summary} omits the log (lists stay light); {@code detail} carries it.
 * {@code name} is the target-name snapshot taken at trigger time.
 */
public record RunResponse(
        Long id,
        Long projectId,
        String targetType,
        Long targetId,
        String name,
        String status,
        String trigger,
        String triggeredBy,
        int stepTotal,
        int stepCompleted,
        Long durationMs,
        Instant startedAt,
        Instant finishedAt,
        Instant createdAt,
        String log,
        String error) {

    public static RunResponse summary(Run run) {
        return build(run, null);
    }

    public static RunResponse detail(Run run) {
        return build(run, run.getLog());
    }

    private static RunResponse build(Run run, String log) {
        return new RunResponse(run.getId(), run.getProjectId(),
                run.getTargetType().name(), run.getTargetId(), run.getTargetName(),
                run.getStatus().name(), run.getTrigger().name(), run.getTriggeredBy(),
                run.getStepTotal(), run.getStepCompleted(), run.getDurationMs(),
                run.getStartedAt(), run.getFinishedAt(), run.getCreatedAt(),
                log, run.getError());
    }
}