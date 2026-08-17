package com.intertec.autoops.core.service;

import com.intertec.autoops.core.client.EntitlementClient;
import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.repo.JobRepository;
import io.micrometer.core.instrument.MeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;

import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Scheduler poll behavior with the lease and the tenant entitlement gate
 * mocked at their seams — no Spring context needed.
 */
class JobSchedulerTest {

    private JobRepository jobRepository;
    private RunService runService;
    private SchedulerLeaseService leaseService;
    private EntitlementClient entitlementClient;
    private JobScheduler scheduler;

    private static final EntitlementClient.Decision ALLOWED =
            new EntitlementClient.Decision(true, "ok", null, null);
    private static final EntitlementClient.Decision EXPIRED =
            new EntitlementClient.Decision(false, "trial_expired", null, null);
    private static final EntitlementClient.Decision OUTAGE =
            new EntitlementClient.Decision(false, EntitlementClient.UNAVAILABLE, null, null);

    @BeforeEach
    void setUp() {
        jobRepository = mock(JobRepository.class);
        runService = mock(RunService.class);
        leaseService = mock(SchedulerLeaseService.class);
        entitlementClient = mock(EntitlementClient.class);
        scheduler = new JobScheduler(jobRepository, runService, leaseService,
                entitlementClient, emptyProvider(), emptyProvider(),
                java.time.Duration.ofMinutes(10));
        when(jobRepository.findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtIsNull())
                .thenReturn(List.of());
    }

    private Job dueJob(String tenant) {
        Job job = new Job();
        job.setTenantId(tenant);
        job.setName("nightly");
        job.setSchedule("0 0 * * *");
        job.setNextRunAt(Instant.now().minusSeconds(60));
        return job;
    }

    /** A scheduled job holding an arbitrary future fire time. */
    private Job futureJob(String cron, Instant storedNextRun) {
        Job job = new Job();
        job.setTenantId("acme");
        job.setName("drifted");
        job.setSchedule(cron);
        job.setScheduleTimezone("Asia/Kolkata");
        job.setNextRunAt(storedNextRun);
        return job;
    }

    // ---- drift repair ----

    @Test
    void repairsAFireTimeTheCronCouldNeverHaveProduced() {
        // The shape that silently kills a schedule: "every 15 minutes" with a
        // stored fire time five months out. It is not NULL so the backfill
        // ignores it, and not due so the poll ignores it — it just never runs.
        Instant wrong = Instant.now().plus(java.time.Duration.ofDays(150));
        Job job = futureJob("*/15 * * * *", wrong);
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(true);
        when(jobRepository.findTop200ByEnabledTrueAndScheduleNotNullAndNextRunAtGreaterThan(any()))
                .thenReturn(List.of(job));

        scheduler.poll();

        assertThat(job.getNextRunAt()).isBefore(wrong);
        assertThat(job.getNextRunAt())
                .as("a 15-minute cron fires within the next 15 minutes")
                .isBefore(Instant.now().plus(java.time.Duration.ofMinutes(16)));
        verify(jobRepository).save(job);
    }

    @Test
    void leavesACorrectFireTimeAlone() {
        // Exactly what the cron computes — including a yearly one, whose next
        // fire is legitimately months away.
        Job job = futureJob("0 2 1 1 *",
                CronSupport.next("0 2 1 1 *", "Asia/Kolkata"));
        Instant before = job.getNextRunAt();
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(true);
        when(jobRepository.findTop200ByEnabledTrueAndScheduleNotNullAndNextRunAtGreaterThan(any()))
                .thenReturn(List.of(job));

        scheduler.poll();

        assertThat(job.getNextRunAt()).isEqualTo(before);
        verify(jobRepository, never()).save(any());
    }

    @Test
    void doesNotTouchAJobWhoseCronNoLongerParses() {
        // advance() clears those when they come due; guessing here would throw
        // away a schedule the operator can still see and fix.
        Job job = futureJob("not a cron", Instant.now().plusSeconds(86_400));
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(true);
        when(jobRepository.findTop200ByEnabledTrueAndScheduleNotNullAndNextRunAtGreaterThan(any()))
                .thenReturn(List.of(job));

        scheduler.poll();

        verify(jobRepository, never()).save(any());
    }

    @Test
    void sweepsOnTheFirstPollThenThrottles() {
        // The first poll to hold the lease sweeps — that is what repairs a
        // database restored moments ago. After that it waits out the interval
        // rather than recomputing every future cron twice a minute.
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(true);

        scheduler.poll();
        scheduler.poll();
        scheduler.poll();

        verify(jobRepository, times(1))
                .findTop200ByEnabledTrueAndScheduleNotNullAndNextRunAtGreaterThan(any());
    }

    @Test
    void nonLeaderInstancesSkipTheDriftSweepToo() {
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(false);

        scheduler.poll();

        verify(jobRepository, never())
                .findTop200ByEnabledTrueAndScheduleNotNullAndNextRunAtGreaterThan(any());
    }

    @Test
    void nonLeaderInstancesSkipTheWholePoll() {
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(false);
        scheduler.poll();
        verify(jobRepository, never())
                .findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtLessThanEqual(any());
        verify(runService, never()).runScheduled(any());
    }

    @Test
    void leaderFiresDueJobsForEntitledTenants() {
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(true);
        when(jobRepository.findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtLessThanEqual(any()))
                .thenReturn(List.of(dueJob("acme")));
        when(entitlementClient.checkTenant("acme")).thenReturn(ALLOWED);

        scheduler.poll();

        verify(runService).runScheduled(any());
        verify(jobRepository).save(any()); // next_run_at advanced
    }

    @Test
    void expiredTenantsAreSkippedButTheCronSlotStillAdvances() {
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(true);
        when(jobRepository.findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtLessThanEqual(any()))
                .thenReturn(List.of(dueJob("deadbeat")));
        when(entitlementClient.checkTenant("deadbeat")).thenReturn(EXPIRED);

        scheduler.poll();

        verify(runService, never()).runScheduled(any());
        verify(jobRepository).save(any()); // must not spin on the same slot
    }

    @Test
    void oneDecisionPerTenantPerPollNotPerJob() {
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(true);
        when(jobRepository.findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtLessThanEqual(any()))
                .thenReturn(List.of(dueJob("acme"), dueJob("acme"), dueJob("acme")));
        when(entitlementClient.checkTenant("acme")).thenReturn(ALLOWED);

        scheduler.poll();

        verify(entitlementClient, times(1)).checkTenant("acme");
        verify(runService, times(3)).runScheduled(any());
    }

    @Test
    void subscriptionServiceOutageDoesNotStopTheScheduler() {
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(true);
        when(jobRepository.findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtLessThanEqual(any()))
                .thenReturn(List.of(dueJob("acme")));
        when(entitlementClient.checkTenant("acme")).thenReturn(OUTAGE);

        scheduler.poll();

        verify(runService).runScheduled(any()); // outage ≠ expiry
    }

    // ---- DST fall-back de-duplication ----
    //
    // America/Chicago 2026-11-01: 01:30 local happens at 06:30Z (-05:00) and
    // again at 07:30Z (-06:00). The cron legitimately resolves to both, so the
    // scheduler must collapse them to one run.

    private static final ZoneId CHICAGO = ZoneId.of("America/Chicago");
    private static final Instant FALLBACK_FIRST = Instant.parse("2026-11-01T06:30:00Z");
    private static final Instant FALLBACK_SECOND = Instant.parse("2026-11-01T07:30:00Z");

    private Job chicagoJob(Instant dueAt) {
        Job job = new Job();
        job.setTenantId("acme");
        job.setName("nightly");
        job.setSchedule("30 1 * * *");
        job.setScheduleTimezone("America/Chicago");
        job.setNextRunAt(dueAt);
        return job;
    }

    /** Sanity check on the fixture: both instants really are the same local time. */
    @Test
    void bothFallBackInstantsAreTheSameLocalWallClock() {
        assertThat(FALLBACK_FIRST.atZone(CHICAGO).toLocalDateTime())
                .isEqualTo(FALLBACK_SECOND.atZone(CHICAGO).toLocalDateTime())
                .isEqualTo(LocalDateTime.parse("2026-11-01T01:30:00"));
    }

    @Test
    void theRepeatedFallBackHourFiresOnlyOnce() {
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(true);
        when(entitlementClient.checkTenant("acme")).thenReturn(ALLOWED);
        Job job = chicagoJob(FALLBACK_FIRST);

        // First of the two instants: runs, and claims the local slot.
        when(jobRepository.findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtLessThanEqual(any()))
                .thenReturn(List.of(job));
        scheduler.poll();

        verify(runService, times(1)).runScheduled(job);
        assertThat(job.getLastFiredLocal()).isEqualTo(LocalDateTime.parse("2026-11-01T01:30:00"));

        // Second instant, same wall clock: suppressed, but still advanced.
        job.setNextRunAt(FALLBACK_SECOND);
        scheduler.poll();

        verify(runService, times(1)).runScheduled(job); // still once, not twice
        // Suppressed, but NOT stuck: advance() re-anchors on the real now, so
        // the slot moves forward and the poller does not spin on it.
        assertThat(job.getNextRunAt()).isNotEqualTo(FALLBACK_SECOND).isAfter(Instant.now());
    }

    @Test
    void anOrdinaryNextDaySlotStillFires() {
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(true);
        when(entitlementClient.checkTenant("acme")).thenReturn(ALLOWED);
        Job job = chicagoJob(FALLBACK_FIRST);
        when(jobRepository.findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtLessThanEqual(any()))
                .thenReturn(List.of(job));
        scheduler.poll();

        // The next day is a different local wall clock — must not be deduped.
        job.setNextRunAt(Instant.parse("2026-11-02T07:30:00Z"));
        scheduler.poll();

        verify(runService, times(2)).runScheduled(job);
    }

    @Test
    void aDeniedTenantDoesNotClaimTheSlotSoTheSecondInstantStillRuns() {
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(true);
        Job job = chicagoJob(FALLBACK_FIRST);
        when(jobRepository.findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtLessThanEqual(any()))
                .thenReturn(List.of(job));

        when(entitlementClient.checkTenant("acme")).thenReturn(EXPIRED);
        scheduler.poll();
        verify(runService, never()).runScheduled(any());
        assertThat(job.getLastFiredLocal()).isNull();

        // Subscription recovers between the two instants: the run is not lost.
        job.setNextRunAt(FALLBACK_SECOND);
        when(entitlementClient.checkTenant("acme")).thenReturn(ALLOWED);
        scheduler.poll();
        verify(runService, times(1)).runScheduled(job);
    }

    @Test
    void aFailedQueueAttemptDoesNotClaimTheSlot() {
        when(leaseService.tryAcquire(JobScheduler.LEASE_NAME)).thenReturn(true);
        when(entitlementClient.checkTenant("acme")).thenReturn(ALLOWED);
        Job job = chicagoJob(FALLBACK_FIRST);
        when(jobRepository.findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtLessThanEqual(any()))
                .thenReturn(List.of(job));
        doThrow(new RuntimeException("queue down")).when(runService).runScheduled(job);

        scheduler.poll();

        assertThat(job.getLastFiredLocal()).isNull(); // nothing ran, nothing claimed
        // ...but the slot still advanced, so a broken queue cannot spin the poller.
        assertThat(job.getNextRunAt()).isNotEqualTo(FALLBACK_FIRST).isAfter(Instant.now());
    }

    /** Generic so it serves both optional collaborators the scheduler takes. */
    private static <T> ObjectProvider<T> emptyProvider() {
        return new ObjectProvider<>() {
            @Override
            public T getIfAvailable() {
                return null;
            }

            @Override
            public T getObject() {
                throw new UnsupportedOperationException();
            }
        };
    }
}
