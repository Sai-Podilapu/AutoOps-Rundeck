package com.intertec.autoops.core.service;

import com.intertec.autoops.core.client.PluginClient;
import com.intertec.autoops.core.config.CoreProperties;
import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.domain.Run;
import com.intertec.autoops.core.domain.RunStatus;
import com.intertec.autoops.core.repo.JobRepository;
import com.intertec.autoops.core.repo.RunRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

/**
 * Finds the two problems that produce no run-engine event at all.
 *
 * <p>Everything else the platform notifies about is a transition the engine
 * makes: a run starts, succeeds, fails. These two are the absence of one.
 *
 * <ul>
 *   <li><b>MISSED</b> — a scheduled job is overdue and nothing fired. This
 *       means {@link JobScheduler} is not running (no leader, crashed, or the
 *       whole service was down), because a healthy scheduler always advances
 *       {@code nextRunAt}. Nothing else in the platform detects this, and it
 *       is the quietest possible failure: no run row, no log line, no alert —
 *       just a backup that has not happened since Tuesday.</li>
 *   <li><b>STALLED</b> — a run has been RUNNING far past its threshold. A
 *       hung step holds the run open indefinitely; without this it produces
 *       neither SUCCEEDED nor FAILED and the tenant hears nothing at all.</li>
 * </ul>
 *
 * <p>Leader-elected on its own lease so a multi-instance deployment alerts
 * once, not once per replica. Both checks are marker-guarded in the database
 * so a persisting problem is reported once rather than every sweep — see
 * {@code V26__lifecycle_notification_markers.sql}.
 */
@Component
@ConditionalOnProperty(value = "autoops.core.plugin.enabled", havingValue = "true",
        matchIfMissing = true)
public class NotificationWatchdog {

    private static final Logger log = LoggerFactory.getLogger(NotificationWatchdog.class);

    static final String LEASE_NAME = "notification-watchdog";

    private final JobRepository jobRepository;
    private final RunRepository runRepository;
    private final SchedulerLeaseService leaseService;
    private final LifecycleNotifier lifecycleNotifier;
    private final CoreProperties properties;

    public NotificationWatchdog(JobRepository jobRepository,
                                RunRepository runRepository,
                                SchedulerLeaseService leaseService,
                                LifecycleNotifier lifecycleNotifier,
                                CoreProperties properties) {
        this.jobRepository = jobRepository;
        this.runRepository = runRepository;
        this.leaseService = leaseService;
        this.lifecycleNotifier = lifecycleNotifier;
        this.properties = properties;
    }

    @Scheduled(initialDelayString = "${autoops.core.plugin.watchdog-interval:5m}",
            fixedDelayString = "${autoops.core.plugin.watchdog-interval:5m}")
    @Transactional
    public void sweep() {
        if (!leaseService.tryAcquire(LEASE_NAME)) {
            return; // another instance leads; it will raise these
        }
        Instant now = Instant.now();
        reportMissedSchedules(now);
        reportStalledRuns(now);
    }

    /**
     * Jobs whose due time passed longer ago than the grace period.
     *
     * <p>The grace period has to comfortably exceed the scheduler's poll
     * interval. A job one second past due is not missed — it is about to run,
     * and reporting it would make the alert meaningless.
     */
    private void reportMissedSchedules(Instant now) {
        Instant cutoff = now.minus(properties.getPlugin().getMissedAfter());
        List<Job> overdue =
                jobRepository.findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtLessThanEqual(cutoff);
        for (Job job : overdue) {
            Instant dueAt = job.getNextRunAt();
            if (dueAt == null || dueAt.equals(job.getMissedNotifiedFor())) {
                continue; // already reported this exact slot
            }
            lifecycleNotifier.scheduleMissed(job, dueAt,
                    "Due at " + dueAt + " but nothing ran. The scheduler may not be running.");
            job.setMissedNotifiedFor(dueAt);
            jobRepository.save(job);
            log.warn("Job {} (tenant {}) is overdue since {} — reported as MISSED",
                    job.getId(), job.getTenantId(), dueAt);
        }
    }

    /** Runs still open past the threshold, each reported exactly once. */
    private void reportStalledRuns(Instant now) {
        Instant cutoff = now.minus(properties.getPlugin().getStalledAfter());
        List<Run> stalled = runRepository
                .findTop50ByStatusAndStartedAtLessThanAndStalledNotifiedAtIsNull(
                        RunStatus.RUNNING, cutoff);
        if (stalled.isEmpty()) {
            return;
        }
        List<PluginClient.LifecycleEvent> events = lifecycleNotifier.stalledEvents(stalled, now);
        // Mark before sending: a duplicate alert is far more damaging to trust
        // than a missed one here, and the send is best-effort either way.
        List<Run> marked = new ArrayList<>();
        for (Run run : stalled) {
            run.setStalledNotifiedAt(now);
            marked.add(run);
        }
        runRepository.saveAll(marked);
        lifecycleNotifier.publishAll(events);
        log.warn("Reported {} run(s) still running past {}", stalled.size(), cutoff);
    }
}
