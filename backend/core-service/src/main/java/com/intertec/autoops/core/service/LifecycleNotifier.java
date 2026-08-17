package com.intertec.autoops.core.service;

import com.intertec.autoops.core.client.PluginClient;
import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.domain.Run;
import com.intertec.autoops.core.domain.RunStatus;
import com.intertec.autoops.core.repo.ProjectRepository;
import com.intertec.autoops.core.repo.RunRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/**
 * Translates run-engine and scheduler events into the vocabulary
 * plugin-service subscribes to, then hands them over.
 *
 * <p>Sits between the two so neither has to know the other exists: the run
 * engine keeps speaking in {@link RunStatus}, plugin-service keeps speaking in
 * lifecycle events, and the mapping — including the two events that have no
 * status at all — lives here.
 *
 * <p>Like {@link PluginClient}, nothing here throws. A notification is never
 * worth failing a run over.
 */
@Service
public class LifecycleNotifier {

    private static final Logger log = LoggerFactory.getLogger(LifecycleNotifier.class);

    /** A previous run in one of these states is what makes a success a recovery. */
    private static final Set<RunStatus> FINISHED =
            Set.of(RunStatus.SUCCEEDED, RunStatus.FAILED, RunStatus.CANCELED);

    private final PluginClient pluginClient;
    private final RunRepository runRepository;
    private final ProjectRepository projectRepository;

    public LifecycleNotifier(PluginClient pluginClient, RunRepository runRepository,
                             ProjectRepository projectRepository) {
        this.pluginClient = pluginClient;
        this.runRepository = runRepository;
        this.projectRepository = projectRepository;
    }

    /** QUEUED — accepted, nothing executed yet. */
    public void runQueued(Run run) {
        publish(run, "QUEUED", null, null);
    }

    /**
     * STARTED — the engine moved the run to RUNNING.
     *
     * <p>{@code RunStatus} has no STARTED member; RUNNING is the transition
     * that means it, so the mapping is made here rather than by widening that
     * enum, which the whole platform reads.
     */
    public void runStarted(Run run) {
        publish(run, "STARTED", null, null);
    }

    /**
     * The terminal event for a finished run, plus RECOVERED where it applies.
     *
     * <p>RECOVERED is emitted <em>in addition to</em> SUCCEEDED, never instead
     * of it. Swapping them would mean a tenant subscribed to SUCCEEDED silently
     * missed the one success they most wanted to see.
     */
    public void runFinished(Run run) {
        String event = switch (run.getStatus()) {
            case SUCCEEDED -> "SUCCEEDED";
            case FAILED -> "FAILED";
            case CANCELED -> "CANCELED";
            // QUEUED and RUNNING are not terminal; finish() cannot reach here
            // with them, and inventing an event for one would be a lie.
            default -> null;
        };
        if (event == null) {
            return;
        }
        Long durationSeconds = run.getDurationMs() == null
                ? null : run.getDurationMs() / 1000;
        publish(run, event, run.getError(), durationSeconds);

        if (run.getStatus() == RunStatus.SUCCEEDED && recoversAFailure(run)) {
            publish(run, "RECOVERED",
                    "The previous run of this " + label(run) + " failed.", durationSeconds);
        }
    }

    /**
     * MISSED — a scheduled window passed and nothing ran.
     *
     * <p>The one event with no run behind it, which is exactly why it matters:
     * a job that never starts produces no FAILED, no row, and no trace. It is
     * the difference between "the backup failed" and the far quieter "the
     * backup has not run since Tuesday".
     */
    public void scheduleMissed(Job job, Instant slot, String reason) {
        try {
            pluginClient.publish(new PluginClient.LifecycleEvent(
                    job.getTenantId(),
                    "JOB",
                    job.getId(),
                    job.getName(),
                    "MISSED",
                    null,
                    job.getProject() == null ? null : job.getProject().getId(),
                    projectName(job.getProject() == null ? null : job.getProject().getId(),
                            job.getTenantId()),
                    "schedule",
                    reason,
                    slot == null ? Instant.now() : slot,
                    null));
        } catch (Exception ex) {
            log.debug("Could not report MISSED for job {}: {}", job.getId(), ex.getMessage());
        }
    }

    /** STALLED — still RUNNING far past its threshold. Batched by the watchdog. */
    public List<PluginClient.LifecycleEvent> stalledEvents(List<Run> runs, Instant now) {
        List<PluginClient.LifecycleEvent> events = new ArrayList<>();
        for (Run run : runs) {
            try {
                long openFor = run.getStartedAt() == null
                        ? 0 : Duration.between(run.getStartedAt(), now).toSeconds();
                events.add(new PluginClient.LifecycleEvent(
                        run.getTenantId(),
                        run.getTargetType().name(),
                        run.getTargetId(),
                        run.getTargetName(),
                        "STALLED",
                        run.getId(),
                        run.getProjectId(),
                        projectName(run.getProjectId(), run.getTenantId()),
                        run.getTriggeredBy(),
                        "Still running after " + humanize(openFor) + ".",
                        now,
                        openFor));
            } catch (Exception ex) {
                log.debug("Could not build STALLED event for run {}: {}",
                        run.getId(), ex.getMessage());
            }
        }
        return events;
    }

    public void publishAll(List<PluginClient.LifecycleEvent> events) {
        pluginClient.publishAll(events);
    }

    // ------------------------------------------------------------------

    private void publish(Run run, String event, String detail, Long durationSeconds) {
        try {
            pluginClient.publish(new PluginClient.LifecycleEvent(
                    run.getTenantId(),
                    run.getTargetType().name(),
                    run.getTargetId(),
                    run.getTargetName(),
                    event,
                    run.getId(),
                    run.getProjectId(),
                    projectName(run.getProjectId(), run.getTenantId()),
                    run.getTriggeredBy() != null
                            ? run.getTriggeredBy() : run.getTrigger().name().toLowerCase(),
                    detail,
                    Instant.now(),
                    durationSeconds));
        } catch (Exception ex) {
            log.debug("Could not report {} for run {}: {}", event, run.getId(), ex.getMessage());
        }
    }

    /** True when the run immediately before this one for the same target failed. */
    private boolean recoversAFailure(Run run) {
        try {
            return runRepository
                    .findFirstByTenantIdAndTargetTypeAndTargetIdAndStatusInAndIdLessThanOrderByIdDesc(
                            run.getTenantId(), run.getTargetType(), run.getTargetId(),
                            FINISHED, run.getId())
                    .map(previous -> previous.getStatus() == RunStatus.FAILED)
                    .orElse(false);
        } catch (Exception ex) {
            // A first-ever success is not a recovery, and neither is one we
            // cannot classify. Staying quiet beats crying wolf.
            return false;
        }
    }

    /** Tenant-scoped, so a mismatched projectId yields no name rather than another's. */
    private String projectName(Long projectId, String tenantId) {
        if (projectId == null) {
            return null;
        }
        try {
            return projectRepository.findByIdAndTenantId(projectId, tenantId)
                    .map(project -> project.getName())
                    .orElse(null);
        } catch (Exception ex) {
            return null;
        }
    }

    private String label(Run run) {
        return run.getTargetType().name().toLowerCase();
    }

    private static String humanize(long seconds) {
        if (seconds < 3600) {
            return (seconds / 60) + " minutes";
        }
        long hours = seconds / 3600;
        long minutes = (seconds % 3600) / 60;
        return minutes == 0 ? hours + " hours" : hours + "h " + minutes + "m";
    }
}
