package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.ModelProvider;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface ModelProviderRepository extends JpaRepository<ModelProvider, Long> {

    List<ModelProvider> findByTenantIdOrderByCreatedAtDesc(String tenantId);

    Optional<ModelProvider> findByIdAndTenantId(Long id, String tenantId);

    /** Backs the (tenant, kind, name) uniqueness the schema enforces. */
    Optional<ModelProvider> findByTenantIdAndKindAndName(String tenantId,
                                                         ModelProvider.Kind kind, String name);
}
