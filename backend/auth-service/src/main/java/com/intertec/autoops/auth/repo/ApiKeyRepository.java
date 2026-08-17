package com.intertec.autoops.auth.repo;

import com.intertec.autoops.auth.domain.ApiKey;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface ApiKeyRepository extends JpaRepository<ApiKey, Long> {

    List<ApiKey> findByTenantIdAndRevokedAtIsNullOrderByCreatedAtDesc(String tenantId);

    Optional<ApiKey> findByIdAndTenantId(Long id, String tenantId);

    Optional<ApiKey> findByKeyHashAndRevokedAtIsNull(String keyHash);
}
