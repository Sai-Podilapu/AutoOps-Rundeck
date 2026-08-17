package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.GovernancePolicySetting;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface GovernancePolicyRepository extends JpaRepository<GovernancePolicySetting, Long> {

    List<GovernancePolicySetting> findByTenantId(String tenantId);

    Optional<GovernancePolicySetting> findByTenantIdAndPolicy(String tenantId, String policy);
}