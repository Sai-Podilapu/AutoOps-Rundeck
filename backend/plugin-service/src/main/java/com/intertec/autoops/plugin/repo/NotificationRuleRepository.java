package com.intertec.autoops.plugin.repo;

import com.intertec.autoops.plugin.domain.NotificationRule;
import com.intertec.autoops.plugin.domain.TargetType;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

/** Tenant-scoped throughout, for the same reason as the installation repo. */
public interface NotificationRuleRepository extends JpaRepository<NotificationRule, Long> {

    List<NotificationRule> findByTenantIdOrderByIdDesc(String tenantId);

    Optional<NotificationRule> findByIdAndTenantId(Long id, String tenantId);

    List<NotificationRule> findByTenantIdAndInstallationId(String tenantId, Long installationId);

    /**
     * The dispatch hot path. Narrowed to tenant + target type in SQL; the
     * wildcard logic (target vs project vs workspace) is then applied in
     * {@link NotificationRule#matches} rather than expressed as a four-way
     * OR here, where a null-handling mistake would silently widen a rule
     * across projects.
     */
    List<NotificationRule> findByTenantIdAndTargetTypeAndEnabledTrue(String tenantId,
                                                                     TargetType targetType);

    void deleteByTenantIdAndInstallationId(String tenantId, Long installationId);

    long countByTenantId(String tenantId);
}
