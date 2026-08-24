package com.intertec.autoops.rundeck.repo;

import com.intertec.autoops.rundeck.domain.RundeckProject;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;

/**
 * Always looked up by (tenant, project) together. There is no finder that takes
 * a Rundeck project NAME: resolving a name back to a scope would be a way to
 * reach a mapping the caller's tenant does not own.
 */
public interface RundeckProjectRepository extends JpaRepository<RundeckProject, Long> {

    Optional<RundeckProject> findByTenantIdAndProjectId(String tenantId, Long projectId);
}
