package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.Secret;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface SecretRepository extends JpaRepository<Secret, Long> {

    List<Secret> findByTenantIdOrderByPathAsc(String tenantId);

    Optional<Secret> findByIdAndTenantId(Long id, String tenantId);

    boolean existsByTenantIdAndPath(String tenantId, String path);
}
