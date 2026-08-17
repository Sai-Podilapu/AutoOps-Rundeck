package com.intertec.autoops.subscription.repo;

import com.intertec.autoops.subscription.domain.SubscriptionAuditLog;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface SubscriptionAuditLogRepository extends JpaRepository<SubscriptionAuditLog, Long> {

    List<SubscriptionAuditLog> findByTenantIdOrderByCreatedAtDesc(String tenantId);

    /** Provider view: newest billing events across every tenant. */
    List<SubscriptionAuditLog> findTop200ByOrderByCreatedAtDesc();
}
