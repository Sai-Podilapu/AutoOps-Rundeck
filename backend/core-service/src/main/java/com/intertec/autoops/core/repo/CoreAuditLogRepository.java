package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.CoreAuditLog;
import org.springframework.data.jpa.repository.JpaRepository;

import java.time.Instant;
import java.util.List;

public interface CoreAuditLogRepository extends JpaRepository<CoreAuditLog, Long> {

    List<CoreAuditLog> findTop200ByTenantIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
            String tenantId, Instant since);

    List<CoreAuditLog> findTop200ByTenantIdAndProjectIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
            String tenantId, Long projectId, Instant since);
}
