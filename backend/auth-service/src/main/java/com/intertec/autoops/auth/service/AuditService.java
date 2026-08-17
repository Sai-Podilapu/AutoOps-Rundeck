package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.domain.AuditEventType;
import com.intertec.autoops.auth.domain.AuthAuditLog;
import com.intertec.autoops.auth.repo.AuthAuditLogRepository;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;

/**
 * Best-effort security event trail. Auditing must never break the main flow,
 * and `detail` must never contain OTPs, tokens, or hashes.
 *
 * <p>Every event also increments the {@code auth_events_total} Prometheus
 * counter (tag {@code type}) — alert on spikes of REFRESH_REUSE,
 * LOGIN_FAILURE, or RATE_LIMITED.
 */
@Service
public class AuditService {

    private static final Logger log = LoggerFactory.getLogger(AuditService.class);

    private final AuthAuditLogRepository auditLogRepository;
    /** Nullable: slice tests have no MeterRegistry; prod wires Prometheus. */
    private final MeterRegistry meterRegistry;

    public AuditService(AuthAuditLogRepository auditLogRepository,
                        ObjectProvider<MeterRegistry> meterRegistry) {
        this.auditLogRepository = auditLogRepository;
        this.meterRegistry = meterRegistry.getIfAvailable();
    }

    public void record(AuditEventType eventType, Long userId, String email, String tenantId,
                       String sessionId, String ipAddress, String userAgent, String detail) {
        if (meterRegistry != null) {
            meterRegistry.counter("auth_events_total", "type", eventType.name()).increment();
        }
        try {
            AuthAuditLog entry = new AuthAuditLog();
            entry.setEventType(eventType);
            entry.setUserId(userId);
            entry.setEmail(email);
            entry.setTenantId(tenantId);
            entry.setSessionId(sessionId);
            entry.setIpAddress(ipAddress);
            entry.setUserAgent(truncate(userAgent, 512));
            entry.setDetail(truncate(detail, 1024));
            auditLogRepository.save(entry);
        } catch (Exception ex) {
            log.error("Failed to write audit event {}: {}", eventType, ex.getMessage());
        }
    }

    private String truncate(String value, int maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.substring(0, maxLength);
    }
}
