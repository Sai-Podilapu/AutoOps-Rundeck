package com.intertec.autoops.plugin.repo;

import com.intertec.autoops.plugin.domain.PluginInstallation;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

/**
 * Every finder carries {@code tenantId}. Reading by id alone is what would let
 * one workspace test, edit or delete another's Slack channel, so there is
 * deliberately no {@code findById} exposed on this interface — inherit it from
 * {@link JpaRepository} only, and never call it from a request path.
 */
public interface PluginInstallationRepository extends JpaRepository<PluginInstallation, Long> {

    List<PluginInstallation> findByTenantIdOrderByDisplayNameAsc(String tenantId);

    Optional<PluginInstallation> findByIdAndTenantId(Long id, String tenantId);

    boolean existsByTenantIdAndDisplayName(String tenantId, String displayName);

    boolean existsByTenantIdAndDisplayNameAndIdNot(String tenantId, String displayName, Long id);

    List<PluginInstallation> findByTenantIdAndPluginKey(String tenantId, String pluginKey);

    long countByTenantId(String tenantId);
}
