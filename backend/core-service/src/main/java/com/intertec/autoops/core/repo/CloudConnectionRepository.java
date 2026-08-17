package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.CloudConnection;
import com.intertec.autoops.core.domain.ConnectionStatus;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface CloudConnectionRepository extends JpaRepository<CloudConnection, Long> {

    List<CloudConnection> findByTenantIdOrderByCreatedAtDesc(String tenantId);

    /** Tenant isolation: every by-id lookup is scoped to the caller's tenant. */
    Optional<CloudConnection> findByIdAndTenantId(Long id, String tenantId);

    /** Quota basis: only CONNECTED connections count toward MAX_CLOUD_INTEGRATIONS. */
    long countByTenantIdAndStatus(String tenantId, ConnectionStatus status);

    boolean existsByTenantIdAndNameAndStatus(String tenantId, String name, ConnectionStatus status);

    /**
     * Any status: the {@code uq_cloud_tenant_name} unique key covers
     * (tenant_id, name) whether the row is connected or not, so connect() has
     * to see disconnected holders of a name too — see its reconnect path.
     */
    Optional<CloudConnection> findFirstByTenantIdAndName(String tenantId, String name);

    /** Step "connection" binding: resolve a CONNECTED connection by its name. */
    Optional<CloudConnection> findFirstByTenantIdAndNameAndStatus(
            String tenantId, String name, ConnectionStatus status);

    /** Fallback binding: the tenant's CONNECTED connections for given platforms. */
    List<CloudConnection> findByTenantIdAndStatusAndPlatformIn(
            String tenantId, ConnectionStatus status,
            java.util.Collection<com.intertec.autoops.core.domain.CloudPlatform> platforms);

    /** Which cloud accounts a tenant still holds — see CloudAccountRegistry. */
    List<CloudConnection> findByTenantIdAndStatus(String tenantId, ConnectionStatus status);

    /**
     * Cross-tenant on purpose: the startup reconciliation that registers
     * pre-existing connections has to see every tenant's.
     */
    List<CloudConnection> findByStatus(ConnectionStatus status);
}
