package com.intertec.autoops.agent.repo;

import com.intertec.autoops.agent.domain.Agent;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface AgentRepository extends JpaRepository<Agent, Long> {

    List<Agent> findByProjectIdAndTenantIdOrderByCreatedAtDesc(Long projectId, String tenantId);

    /** Tenant isolation: every by-id lookup is scoped to the caller's tenant. */
    Optional<Agent> findByIdAndTenantId(Long id, String tenantId);

    /** Quota basis: agents share MAX_AUTOMATIONS with workflows. */
    long countByTenantId(String tenantId);

    boolean existsByProjectIdAndName(Long projectId, String name);

    /**
     * Rollout de-dupe: a project holds at most one delivered copy of a given
     * catalog item. Scoped to the project rather than the tenant on purpose —
     * delivering the same agent into two of a customer's projects is a
     * legitimate rollout, two copies in ONE project is not.
     *
     * <p>Not covered by {@link #existsByProjectIdAndName}: that compares NAMES,
     * so renaming the catalog item and rolling out again slips a second copy of
     * the same source past it.
     */
    boolean existsByProjectIdAndSourceId(Long projectId, Long sourceId);
}
