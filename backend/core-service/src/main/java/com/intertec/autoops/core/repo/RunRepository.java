package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.Run;
import com.intertec.autoops.core.domain.RunStatus;
import com.intertec.autoops.core.domain.RunTargetType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.Collection;
import java.util.List;
import java.util.Optional;

public interface RunRepository extends JpaRepository<Run, Long> {

    /** Tenant isolation: every by-id lookup is scoped to the caller's tenant. */
    Optional<Run> findByIdAndTenantId(Long id, String tenantId);

    /** Newest first, bounded by the plan's retention cutoff (history_days). */
    List<Run> findTop200ByTenantIdAndProjectIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
            String tenantId, Long projectId, Instant cutoff);

    /**
     * One target's history, newest first, same retention bound.
     *
     * <p>The 200-row cap applies WITHIN the target here, which is the whole
     * reason this exists: filtering the project-wide 200 client-side silently
     * truncated a job's history as soon as its neighbours out-ran it.
     */
    List<Run> findTop200ByTenantIdAndProjectIdAndTargetTypeAndTargetIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
            String tenantId, Long projectId, RunTargetType targetType, Long targetId,
            Instant cutoff);

    /**
     * The run immediately before this one for the same target, whatever its
     * outcome. Backs RECOVERED: a success only means "recovered" if what came
     * before it failed.
     *
     * <p>Ordered by id rather than a timestamp because two runs of the same
     * target can share a {@code createdAt} to the microsecond, and id is the
     * only strictly monotonic ordering available.
     */
    Optional<Run> findFirstByTenantIdAndTargetTypeAndTargetIdAndStatusInAndIdLessThanOrderByIdDesc(
            String tenantId, RunTargetType targetType, Long targetId,
            Collection<RunStatus> statuses, Long beforeId);

    /**
     * Runs still open past a threshold — the STALLED watchdog's input.
     * {@code stalledNotifiedAt} null keeps already-reported runs out of the
     * result rather than filtering them in memory every sweep.
     */
    List<Run> findTop50ByStatusAndStartedAtLessThanAndStalledNotifiedAtIsNull(
            RunStatus status, Instant cutoff);

    /** Aggregated run stats per target, over FINISHED (succeeded/failed) runs. */
    interface RunStatsRow {
        Long getTargetId();

        long getTotal();

        long getSucceeded();

        Instant getLastRunAt();

        Double getAvgDurationMs();
    }

    @Query("""
            select r.targetId as targetId, count(r) as total,
                   sum(case when r.status = :succeeded then 1 else 0 end) as succeeded,
                   max(r.startedAt) as lastRunAt, avg(r.durationMs) as avgDurationMs
            from Run r
            where r.tenantId = :tenantId and r.targetType = :targetType
              and r.projectId = :projectId and r.status in :finished
            group by r.targetId""")
    List<RunStatsRow> statsByProject(@Param("tenantId") String tenantId,
                                     @Param("targetType") RunTargetType targetType,
                                     @Param("projectId") Long projectId,
                                     @Param("finished") Collection<RunStatus> finished,
                                     @Param("succeeded") RunStatus succeeded);

    /**
     * Target ids with a run in flight.
     *
     * <p>Separate from the stats above, which aggregate FINISHED runs only and
     * so can never say "this one is running now". Read by the console to show a
     * live badge whatever started the run — an agent, a schedule, the API, or
     * the Run button — instead of the page guessing from its own last click.
     */
    @Query("""
            select distinct r.targetId from Run r
            where r.tenantId = :tenantId and r.targetType = :targetType
              and r.projectId = :projectId and r.status in :active""")
    List<Long> activeTargets(@Param("tenantId") String tenantId,
                             @Param("targetType") RunTargetType targetType,
                             @Param("projectId") Long projectId,
                             @Param("active") Collection<RunStatus> active);

    @Query("""
            select r.targetId as targetId, count(r) as total,
                   sum(case when r.status = :succeeded then 1 else 0 end) as succeeded,
                   max(r.startedAt) as lastRunAt, avg(r.durationMs) as avgDurationMs
            from Run r
            where r.tenantId = :tenantId and r.targetType = :targetType
              and r.targetId = :targetId and r.status in :finished
            group by r.targetId""")
    Optional<RunStatsRow> statsByTarget(@Param("tenantId") String tenantId,
                                        @Param("targetType") RunTargetType targetType,
                                        @Param("targetId") Long targetId,
                                        @Param("finished") Collection<RunStatus> finished,
                                        @Param("succeeded") RunStatus succeeded);

    /** Governance FAILURE_BUDGET basis: finished-run failure counts per project. */
    interface ProjectRunStatsRow {
        Long getProjectId();

        long getTotal();

        long getFailed();
    }

    @Query("""
            select r.projectId as projectId, count(r) as total,
                   sum(case when r.status = :failed then 1 else 0 end) as failed
            from Run r
            where r.tenantId = :tenantId and r.createdAt >= :since and r.status in :finished
            group by r.projectId""")
    List<ProjectRunStatsRow> failureStatsByProject(@Param("tenantId") String tenantId,
                                                   @Param("since") Instant since,
                                                   @Param("finished") Collection<RunStatus> finished,
                                                   @Param("failed") RunStatus failed);
}