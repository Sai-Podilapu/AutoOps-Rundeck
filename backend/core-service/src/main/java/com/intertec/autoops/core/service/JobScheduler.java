package com.intertec.autoops.core.service;

import com.intertec.autoops.core.client.EntitlementClient;
import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.repo.JobRepository;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;
import java.time.LocalDateTime;
import java.util.HashMap;
import java.util.Map;

/**
 * DB-polling cron scheduler: every poll claims enabled jobs whose
 * {@code next_run_at} has passed, queues a SCHEDULE run for each, and
 * advances the fire time.
 *
 * <p><strong>Multi-instance safe:</strong> only the instance holding the
 * {@code job-scheduler} DB lease polls ({@link SchedulerLeaseService}); a
 * crashed leader is replaced within the lease TTL.
 *
 * <p><strong>DST-aware:</strong> each job's cron is a local-time rule in its own
 * zone ({@link CronSupport}). On a fall-back day the same wall-clock time
 * occurs twice, which would otherwise queue two runs an hour apart; the second
 * is suppressed by comparing the slot against {@code jobs.last_fired_local}
 * and counted as {@code core_scheduled_runs_skipped_total{reason="dst_duplicate"}}.
 * A spring-forward day is the mirror case and needs no code: the local time
 * simply does not exist, so the cron skips to the next day on its own.
 *
 * <p><strong>Entitlement-gated:</strong> scheduled runs carry no user token,
 * so each due job's tenant is checked through subscription-service's
 * internal (shared-secret) endpoint. A denied tenant's job is SKIPPED — the
 * cron slot still advances, and {@code core_scheduled_runs_skipped_total}
 * counts it. An UNREACHABLE subscription-service deliberately does NOT stop
 * the scheduler (unlike user mutations, which fail closed): the gate exists
 * to stop expired tenants, not to make every tenant's cron fragile.
 */
@Component
@ConditionalOnProperty(value = "autoops.core.scheduler.enabled", havingValue = "true",
        matchIfMissing = true)
public class JobScheduler {

    private static final Logger log = LoggerFactory.getLogger(JobScheduler.class);

    static final String LEASE_NAME = "job-scheduler";

    private final JobRepository jobRepository;
    private final RunService runService;
    private final SchedulerLeaseService leaseService;
    private final EntitlementClient entitlementClient;
    /** Nullable: slice tests have no MeterRegistry; prod wires Prometheus. */
    private final MeterRegistry meterRegistry;
    /** Nullable in slice tests; outbound channels then hear nothing. */
    private final LifecycleNotifier lifecycleNotifier;

    /** How often the drift sweep runs, throttled inside the 30-second poll. */
    private final Duration driftInterval;

    /** EPOCH so the first poll that holds the lease sweeps immediately. */
    private Instant lastDriftSweep = Instant.EPOCH;

    public JobScheduler(JobRepository jobRepository, RunService runService,
                        SchedulerLeaseService leaseService,
                        EntitlementClient entitlementClient,
                        ObjectProvider<MeterRegistry> meterRegistry,
                        ObjectProvider<LifecycleNotifier> lifecycleNotifier,
                        @Value("${autoops.core.scheduler.drift-interval:10m}")
                        Duration driftInterval) {
        this.jobRepository = jobRepository;
        this.runService = runService;
        this.leaseService = leaseService;
        this.entitlementClient = entitlementClient;
        this.meterRegistry = meterRegistry.getIfAvailable();
        this.lifecycleNotifier = lifecycleNotifier.getIfAvailable();
        this.driftInterval = driftInterval;
    }

    @Scheduled(fixedDelayString = "${autoops.core.scheduler.poll-interval:30s}")
    @Transactional
    public void poll() {
        if (!leaseService.tryAcquire(LEASE_NAME)) {
            return; // another instance leads; it will fire the due jobs
        }
        Instant now = Instant.now();
        // Backfill fire times for scheduled jobs that predate the scheduler.
        for (Job job : jobRepository.findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtIsNull()) {
            advance(job, "backfill");
        }
        // ...and repair the ones holding a fire time their cron disagrees with,
        // which the backfill above cannot see. Starts at EPOCH so the first
        // poll to hold the lease sweeps, then every driftInterval after that.
        if (Duration.between(lastDriftSweep, now).compareTo(driftInterval) >= 0) {
            lastDriftSweep = now;
            sweepDrift(now);
        }
        // One decision per tenant per poll — a tenant with 20 due jobs is
        // checked once, not 20 times.
        Map<String, EntitlementClient.Decision> decisions = new HashMap<>();
        for (Job job : jobRepository.findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtLessThanEqual(now)) {
            LocalDateTime slot = localSlot(job);
            if (isDstRepeat(job, slot)) {
                log.info("Skipping job {} — local slot {} ({}) already ran; DST fall-back repeat",
                        job.getId(), slot, job.getScheduleTimezone());
                count("dst_duplicate");
                advance(job, "dst-duplicate");
                continue;
            }
            EntitlementClient.Decision decision = decisions.computeIfAbsent(
                    job.getTenantId(), entitlementClient::checkTenant);
            Instant dueAt = job.getNextRunAt();
            if (allowed(job, decision)) {
                try {
                    runService.runScheduled(job);
                    // Only a QUEUED run claims the slot: a tenant denied at the
                    // first of the two fall-back instants still gets its run at
                    // the second if the subscription recovers in between.
                    job.setLastFiredLocal(slot);
                } catch (Exception ex) {
                    log.error("Scheduled run of job {} failed to queue: {}", job.getId(),
                            ex.getMessage());
                    // The precise "not running" case, and one that used to
                    // leave nothing behind but this log line: the slot came up
                    // and produced no run at all, so there is no FAILED run to
                    // notice later.
                    notifyMissed(job, dueAt,
                            "The scheduled run could not be queued: " + ex.getMessage());
                }
            } else {
                notifyMissed(job, dueAt, "Skipped — the workspace subscription does not "
                        + "currently allow runs (" + decision.reason() + ").");
            }
            advance(job, "fired");
        }
    }

    /**
     * The wall-clock reading of the slot this job is firing for, in its own
     * zone. Null when the zone is unusable, which disables the de-duplication
     * rather than dropping the run.
     */
    private LocalDateTime localSlot(Job job) {
        try {
            return job.getNextRunAt().atZone(CronSupport.zone(job.getScheduleTimezone()))
                    .toLocalDateTime();
        } catch (Exception ex) {
            return null;
        }
    }

    /**
     * True when this job already queued a run for the same local wall-clock
     * time — which happens exactly once a year, for the hour a fall-back
     * transition repeats. Normal consecutive slots always differ in local date
     * or time, so this never suppresses an ordinary run.
     */
    private boolean isDstRepeat(Job job, LocalDateTime slot) {
        return slot != null && slot.equals(job.getLastFiredLocal());
    }

    /**
     * Reports a slot that produced no run.
     *
     * <p>Does NOT set {@code missedNotifiedFor}: {@link #advance} moves
     * {@code nextRunAt} on to a new slot immediately after this, so the
     * watchdog compares against a different value and cannot double-report.
     * That marker exists for the other case entirely — the scheduler being
     * down, where nothing advances at all.
     */
    private void notifyMissed(Job job, Instant dueAt, String reason) {
        if (lifecycleNotifier != null) {
            lifecycleNotifier.scheduleMissed(job, dueAt, reason);
        }
    }

    private void count(String reason) {
        if (meterRegistry != null) {
            meterRegistry.counter("core_scheduled_runs_skipped_total", "reason", reason)
                    .increment();
        }
    }

    private boolean allowed(Job job, EntitlementClient.Decision decision) {
        if (decision.entitled()) {
            return true;
        }
        if (EntitlementClient.UNAVAILABLE.equals(decision.reason())) {
            // Outage ≠ expiry: run anyway, loudly.
            log.warn("Entitlements unreachable — scheduled job {} (tenant {}) runs unchecked",
                    job.getId(), job.getTenantId());
            return true;
        }
        log.info("Skipping scheduled job {} — tenant {} subscription denies runs ({})",
                job.getId(), job.getTenantId(), decision.reason());
        count(decision.reason());
        return false;
    }

    /**
     * Repairs a stored fire time that its own cron could never have produced.
     *
     * <p>{@link #poll} has two blind spots that meet in the middle. The
     * backfill only rescues a NULL, and the due query only sees rows already
     * past. A row holding a wrong FUTURE instant satisfies neither, so it
     * never fires and nothing ever notices — the schedule page shows "next
     * run: January" beside a cron that reads "every 15 minutes", and the job
     * is simply dead until that date arrives. Rows like that arrive from
     * seeded data, restores, and hand-edited SQL, none of which go through
     * {@link JobService#applySchedule}.
     *
     * <p>The test is the cron's own answer: if the expression's next fire from
     * now is EARLIER than what the row stores, the row is wrong, because the
     * schedule says it should have fired by then. A correct row cannot trip
     * this — its stored value is exactly what the cron computes — and a row
     * that is merely due stores an instant in the past, which is not after
     * anything. A yearly cron is safe for the same reason: stored and expected
     * agree, however distant they both are.
     *
     * <p>Driven from {@link #poll} rather than its own {@code @Scheduled}
     * method, throttled to {@code drift-interval}. A second scheduled method
     * would have to win the lease on its own, and for the first 90 seconds
     * after a restart it cannot: the previous holder's lease has not expired
     * yet. A sweep timed to land in that window does nothing and then waits a
     * full interval — precisely when a restore or a seed load has just made it
     * necessary. Hanging it off the poll means it runs on the first poll that
     * holds the lease, whenever that turns out to be.
     */
    private void sweepDrift(Instant now) {
        for (Job job : jobRepository
                .findTop200ByEnabledTrueAndScheduleNotNullAndNextRunAtGreaterThan(now)) {
            Instant expected;
            try {
                expected = CronSupport.next(job.getSchedule(), job.getScheduleTimezone());
            } catch (Exception ex) {
                continue; // advance() deals with unparseable crons when it fires
            }
            if (expected == null || !job.getNextRunAt().isAfter(expected)) {
                continue;
            }
            log.warn("Job {} stored next run {} is later than its cron '{}' ({}) allows "
                            + "({}) — repairing; it would not have fired until then",
                    job.getId(), job.getNextRunAt(), job.getSchedule(),
                    job.getScheduleTimezone(), expected);
            count("drift_repaired");
            job.setNextRunAt(expected);
            jobRepository.save(job);
        }
    }

    /** Always advance — a job with a broken stored cron must not spin the poller. */
    private void advance(Job job, String cause) {
        try {
            job.setNextRunAt(CronSupport.next(job.getSchedule(), job.getScheduleTimezone()));
        } catch (Exception ex) {
            log.warn("Job {} has an invalid stored schedule '{}' ({}) — clearing it",
                    job.getId(), job.getSchedule(), job.getScheduleTimezone());
            job.setSchedule(null);
            job.setNextRunAt(null);
        }
        jobRepository.save(job);
        log.debug("Job {} next run at {} ({})", job.getId(), job.getNextRunAt(), cause);
    }
}
