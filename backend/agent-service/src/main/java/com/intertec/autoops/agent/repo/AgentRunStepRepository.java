package com.intertec.autoops.agent.repo;

import com.intertec.autoops.agent.domain.AgentRunStep;
import org.springframework.data.jpa.repository.JpaRepository;

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
}
