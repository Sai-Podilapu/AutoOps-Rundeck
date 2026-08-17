package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.Webhook;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface WebhookRepository extends JpaRepository<Webhook, Long> {

    List<Webhook> findByTenantIdOrderByCreatedAtDesc(String tenantId);

    List<Webhook> findByTenantIdAndProjectIdOrderByCreatedAtDesc(String tenantId, Long projectId);

    Optional<Webhook> findByIdAndTenantId(Long id, String tenantId);

    Optional<Webhook> findByToken(String token);
}
