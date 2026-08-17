package com.intertec.autoops.core.web.dto;

import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.service.RunService;

import java.time.Instant;

/**
 * Run stats (successRate/lastRunAt/...) are aggregated from finished runs;
 * null until the job has run at least once (or on create/update responses,
 * which skip the stats lookup — lists refresh them).
 */
public record JobResponse(
        Long id,
        Long projectId,
        String name,
        String group,
        String description,
        String definition,
        int stepCount,
        String schedule,
        String scheduleTimezone,
        Instant nextRunAt,
        boolean enabled,
        boolean requiresApproval,
        Long runsTotal,
        Integer successRate,
        Instant lastRunAt,
        Long avgDurationMs,
        String createdBy,
        Instant createdAt,
        Instant updatedAt) {

    public static JobResponse from(Job job) {
        return from(job, null);
    }

    public static JobResponse from(Job job, RunService.RunStats stats) {
        return new JobResponse(job.getId(), job.getProject().getId(), job.getName(),
                job.getJobGroup(), job.getDescription(), job.getDefinition(),
                job.getStepCount(), job.getSchedule(), job.getScheduleTimezone(),
                job.getNextRunAt(), job.isEnabled(),
                job.isRequiresApproval(),
                stats != null ? stats.total() : null,
                stats != null ? stats.successRate() : null,
                stats != null ? stats.lastRunAt() : null,
                stats != null ? stats.avgDurationMs() : null,
                job.getCreatedBy(), job.getCreatedAt(), job.getUpdatedAt());
    }
}