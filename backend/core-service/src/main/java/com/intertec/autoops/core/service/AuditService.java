package com.intertec.autoops.core.service;

import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.domain.CoreAuditLog;
import com.intertec.autoops.core.repo.CoreAuditLogRepository;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;

/**
 * Best-effort core event trail (same convention as the auth and subscription
 * AuditServices). Recording must never break the mutation it documents, and
 * {@code detail} must never contain credentials or tokens. Writing is
 * unconditional regardless of plan — only READING the log is the AUDIT_LOG
 * plan feature.
 *
 * <p>Every event also increments {@code core_audit_events_total} (tag
 * {@code type}).
 *
 * <p>Mutating services inject this via {@code ObjectProvider} (nullable in
 * slice tests, same pattern as MeterRegistry) — see {@link #record}.
 */
@Service
public class AuditService {

    private static final Logger log = LoggerFactory.getLogger(AuditService.class);

    private final CoreAuditLogRepository auditLogRepository;
    /** Nullable: slice tests have no MeterRegistry; prod wires Prometheus. */
    private final MeterRegistry meterRegistry;

    public AuditService(CoreAuditLogRepository auditLogRepository,
                        ObjectProvider<MeterRegistry> meterRegistry) {
        this.auditLogRepository = auditLogRepository;
        this.meterRegistry = meterRegistry.getIfAvailable();
    }

    public void record(CoreAuditEventType eventType, String tenantId, String actor,
                       Long projectId, String targetType, Object targetId,
                       String targetName, String detail) {
        if (meterRegistry != null) {
            meterRegistry.counter("core_audit_events_total", "type", eventType.name())
                    .increment();
        }
        try {
            CoreAuditLog entry = new CoreAuditLog();
            entry.setEventType(eventType);
            entry.setTenantId(tenantId);
            entry.setActor(actor);
            entry.setProjectId(projectId);
            entry.setTargetType(targetType);
            entry.setTargetId(targetId != null ? String.valueOf(targetId) : null);
            entry.setTargetName(truncate(targetName, 255));
            entry.setDetail(truncate(detail, 1024));
            auditLogRepository.save(entry);
        } catch (Exception ex) {
            log.error("Failed to write audit event {}: {}", eventType, ex.getMessage());
        }
    }

    private static String truncate(String value, int maxLength) {
        return value == null || value.length() <= maxLength ? value
                : value.substring(0, maxLength);
    }
}
