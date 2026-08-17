package com.intertec.autoops.subscription.service;

import com.intertec.autoops.subscription.domain.PlanCode;
import com.intertec.autoops.subscription.domain.SubscriptionAuditLog;
import com.intertec.autoops.subscription.domain.SubscriptionEventType;
import com.intertec.autoops.subscription.repo.SubscriptionAuditLogRepository;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;

/**
 * Best-effort billing event trail (same convention as auth-service's
 * AuditService). Auditing must never break the main flow, and {@code detail}
 * must never contain tokens.
 *
 * <p>Every event also increments the {@code subscription_events_total}
 * Prometheus counter (tag {@code type}) — alert on spikes of CANCELED.
 */
@Service
public class AuditService {

    private static final Logger log = LoggerFactory.getLogger(AuditService.class);

    private final SubscriptionAuditLogRepository auditLogRepository;
    /** Nullable: slice tests have no MeterRegistry; prod wires Prometheus. */
    private final MeterRegistry meterRegistry;

    public AuditService(SubscriptionAuditLogRepository auditLogRepository,
                        ObjectProvider<MeterRegistry> meterRegistry) {
        this.auditLogRepository = auditLogRepository;
        this.meterRegistry = meterRegistry.getIfAvailable();
    }

    public void record(SubscriptionEventType eventType, String tenantId, PlanCode planCode,
                       String actor, String detail) {
        if (meterRegistry != null) {
            meterRegistry.counter("subscription_events_total", "type", eventType.name()).increment();
        }
        try {
            SubscriptionAuditLog entry = new SubscriptionAuditLog();
            entry.setEventType(eventType);
            entry.setTenantId(tenantId);
            entry.setPlanCode(planCode);
            entry.setActor(actor);
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
