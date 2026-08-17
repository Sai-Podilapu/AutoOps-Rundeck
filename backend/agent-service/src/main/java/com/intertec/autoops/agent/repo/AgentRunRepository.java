package com.intertec.autoops.agent.repo;

import com.intertec.autoops.agent.domain.AgentRun;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

/**
 * Every finder takes a tenant id. Agent run ids are global, so a lookup by id
 * alone would let one workspace read another's transcript — and a transcript is
 * the single most revealing row in this service.
 */
public interface AgentRunRepository extends JpaRepository<AgentRun, Long> {

    Optional<AgentRun> findByIdAndTenantId(Long id, String tenantId);

    List<AgentRun> findTop100ByAgentIdAndTenantIdOrderByIdDesc(Long agentId, String tenantId);

    List<AgentRun> findTop100ByTenantIdAndProjectIdOrderByIdDesc(String tenantId, Long projectId);

    /** The resume path: which run is parked on this approval. */
    Optional<AgentRun> findByApprovalReferenceAndTenantId(String approvalReference, String tenantId);

    /** Every run parked on a human, for the poller that chases their verdicts. */
    List<AgentRun> findByStatus(AgentRun.Status status);

    long countByAgentId(Long agentId);
}
