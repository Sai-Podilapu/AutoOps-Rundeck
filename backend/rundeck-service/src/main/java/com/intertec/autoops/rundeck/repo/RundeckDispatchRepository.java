package com.intertec.autoops.rundeck.repo;

import com.intertec.autoops.rundeck.domain.RundeckDispatch;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

/**
 * Dispatch receipts, always read within a tenant.
 *
 * <p>The connection-scoped finders are gone with the connection model: there is
 * one platform engine now, and the question worth asking is "what did this
 * tenant's run do", not "what went to which server".
 */
public interface RundeckDispatchRepository extends JpaRepository<RundeckDispatch, Long> {

    List<RundeckDispatch> findByTenantIdOrderByCreatedAtDesc(String tenantId, Pageable pageable);

    List<RundeckDispatch> findByTenantIdAndRunIdOrderByStepIndexAsc(String tenantId, Long runId);
}
