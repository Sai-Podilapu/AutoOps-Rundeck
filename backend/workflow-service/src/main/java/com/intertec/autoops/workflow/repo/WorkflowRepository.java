package com.intertec.autoops.workflow.repo;

import com.intertec.autoops.workflow.domain.Workflow;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.List;
import java.util.Optional;

public interface WorkflowRepository extends JpaRepository<Workflow, Long> {

    /** Provider console: workflow counts for every tenant, in one query. */
    @Query("SELECT w.tenantId, COUNT(w) FROM Workflow w GROUP BY w.tenantId")
    List<Object[]> countGroupedByTenant();

    List<Workflow> findByProjectIdAndTenantIdOrderByCreatedAtDesc(Long projectId, String tenantId);

    /** Tenant isolation: every by-id lookup is scoped to the caller's tenant. */
    Optional<Workflow> findByIdAndTenantId(Long id, String tenantId);

    /** Quota basis: workflows share MAX_AUTOMATIONS with agents. */
    long countByTenantId(String tenantId);

    boolean existsByProjectIdAndName(Long projectId, String name);

    /**
     * Rollout de-dupe: a project holds at most one delivered copy of a given
     * catalog item. Scoped to the project rather than the tenant on purpose —
     * delivering the same workflow into two of a customer's projects is a
     * legitimate rollout, two copies in ONE project is not.
     *
     * <p>Not covered by {@link #existsByProjectIdAndName}: that compares NAMES,
     * so renaming the catalog item and rolling out again slips a second copy of
     * the same source past it.
     */
    boolean existsByProjectIdAndSourceId(Long projectId, Long sourceId);
}
