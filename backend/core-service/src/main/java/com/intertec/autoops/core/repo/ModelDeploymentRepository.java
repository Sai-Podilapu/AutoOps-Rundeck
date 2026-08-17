package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.ModelDeployment;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Optional;

public interface ModelDeploymentRepository extends JpaRepository<ModelDeployment, Long> {

    List<ModelDeployment> findByProviderIdOrderByModelName(Long providerId);

    /** Every declared model in the workspace, for the one-query model list. */
    List<ModelDeployment> findByTenantId(String tenantId);

    Optional<ModelDeployment> findByIdAndTenantId(Long id, String tenantId);

    /** Backs "re-declaring a model is an update, not a duplicate". */
    Optional<ModelDeployment> findByProviderIdAndModelName(Long providerId, String modelName);

    @Modifying
    @Transactional
    void deleteByProviderId(Long providerId);
}
