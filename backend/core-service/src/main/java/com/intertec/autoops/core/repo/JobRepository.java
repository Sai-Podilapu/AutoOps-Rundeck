package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.Job;
import org.springframework.data.jpa.repository.JpaRepository;

import java.time.Instant;
import java.util.List;
import java.util.Optional;

public interface JobRepository extends JpaRepository<Job, Long> {

    List<Job> findByProjectIdAndTenantIdOrderByCreatedAtDesc(Long projectId, String tenantId);

    /** Tenant isolation: every by-id lookup is scoped to the caller's tenant. */
    Optional<Job> findByIdAndTenantId(Long id, String tenantId);

    /** Quota basis: ALL jobs in the tenant count toward MAX_JOBS. */
    long countByTenantId(String tenantId);

    boolean existsByProjectIdAndName(Long projectId, String name);

    /** Scheduler poll: enabled cron jobs whose next fire time has passed. */
    List<Job> findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtLessThanEqual(Instant now);

    /** Backfill: scheduled jobs that predate the scheduler (no fire time yet). */
    List<Job> findTop50ByEnabledTrueAndScheduleNotNullAndNextRunAtIsNull();

    /**
     * Drift sweep: scheduled jobs whose fire time is still ahead of us.
     *
     * <p>The backfill above only rescues a NULL. A row holding a fire time
     * that its cron could never produce is invisible to both that query and
     * the due query — it is not null and it is not yet due — so it sits there
     * silently never firing. This is the only query that can see one.
     */
    List<Job> findTop200ByEnabledTrueAndScheduleNotNullAndNextRunAtGreaterThan(Instant now);

    /** Governance dashboard: is the cron scheduler doing anything for this tenant? */
    boolean existsByTenantIdAndEnabledTrueAndScheduleNotNull(String tenantId);
}
