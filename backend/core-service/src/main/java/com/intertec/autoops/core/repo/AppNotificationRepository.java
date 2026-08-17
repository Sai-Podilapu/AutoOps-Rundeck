package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.AppNotification;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface AppNotificationRepository extends JpaRepository<AppNotification, Long> {

    List<AppNotification> findTop100ByTenantIdOrderByCreatedAtDesc(String tenantId);

    java.util.Optional<AppNotification> findByIdAndTenantId(Long id, String tenantId);
}
