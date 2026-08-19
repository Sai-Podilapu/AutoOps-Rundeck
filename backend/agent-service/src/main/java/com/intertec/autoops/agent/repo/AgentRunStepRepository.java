package com.intertec.autoops.agent.repo;

import com.intertec.autoops.agent.domain.AgentRunStep;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;

public interface AgentRunStepRepository extends JpaRepository<AgentRunStep, Long> {

    /**
     * Steps are only ever read for a run whose tenant was already checked by
     * {@code AgentRunRepository#findByIdAndTenantId}, so the run id alone is
     * enough here — there is no path to this method that skipped that check.
     */
    List<AgentRunStep> findByRunIdOrderBySeqAsc(Long runId);

    /** Next seq. Counted rather than remembered, so a resumed run continues it. */
    long countByRunId(Long runId);

    /**
     * Every step id of one run — the set of citations a report may legally use.
     *
     * <p>Ids only, deliberately. The check is "was this id issued by THIS run",
     * and loading whole step rows to answer it would pull a run's entire
     * transcript into memory at the moment it finishes. Scoped by run id, which
     * is what makes an id borrowed from a different run fail the check.
     */
    @Query("select s.id from AgentRunStep s where s.runId = :runId")
    List<Long> findIdsByRunId(@Param("runId") Long runId);
}
