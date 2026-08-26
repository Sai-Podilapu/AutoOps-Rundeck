package com.intertec.autoops.rundeck.repo;

import com.intertec.autoops.rundeck.domain.RundeckJob;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

/**
 * Always scoped by tenant. There is no finder that takes a Rundeck job UUID
 * alone: resolving a UUID back to a mapping would be a way to reach a job the
 * caller's tenant does not own.
 */
public interface RundeckJobRepository extends JpaRepository<RundeckJob, Long> {

    Optional<RundeckJob> findByTenantIdAndAutoopsJobId(String tenantId, Long autoopsJobId);

    /** Every engine job in a project — used when a project is archived. */
    List<RundeckJob> findByTenantIdAndProjectId(String tenantId, Long projectId);
}
