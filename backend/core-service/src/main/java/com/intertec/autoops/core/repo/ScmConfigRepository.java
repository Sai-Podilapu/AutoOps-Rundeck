package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.ScmConfig;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface ScmConfigRepository extends JpaRepository<ScmConfig, Long> {

    Optional<ScmConfig> findByProjectIdAndTenantId(Long projectId, String tenantId);

    List<ScmConfig> findByTenantId(String tenantId);
}
