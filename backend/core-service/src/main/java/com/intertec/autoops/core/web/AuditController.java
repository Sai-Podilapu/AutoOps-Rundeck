package com.intertec.autoops.core.web;

import com.intertec.autoops.core.client.SubscriptionInfoClient;
import com.intertec.autoops.core.domain.CoreAuditLog;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.CoreAuditLogRepository;
import com.intertec.autoops.core.service.SubscriptionGate;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.Duration;
import java.time.Instant;
import java.util.List;

/**
 * The searchable audit log — an AUDIT_LOG plan feature (Team+); the one
 * deliberate exception to "reads are never gated", because the log is a paid
 * capability in the plan matrix, not the tenant's own working data. Events
 * are RECORDED for every tenant regardless — an upgrade reveals the full
 * history retroactively (bounded by the plan's retention depth, like runs).
 */
@RestController
@RequestMapping("/api/audit")
public class AuditController {

    private final CoreAuditLogRepository auditLogRepository;
    private final SubscriptionGate gate;
    private final SubscriptionInfoClient subscriptionInfoClient;

    public AuditController(CoreAuditLogRepository auditLogRepository, SubscriptionGate gate,
                           SubscriptionInfoClient subscriptionInfoClient) {
        this.auditLogRepository = auditLogRepository;
        this.gate = gate;
        this.subscriptionInfoClient = subscriptionInfoClient;
    }

    public record AuditEventResponse(Long id, String eventType, String actor, Long projectId,
                                     String targetType, String targetId, String targetName,
                                     String detail, Instant createdAt) {

        static AuditEventResponse from(CoreAuditLog entry) {
            return new AuditEventResponse(entry.getId(), entry.getEventType().name(),
                    entry.getActor(), entry.getProjectId(), entry.getTargetType(),
                    entry.getTargetId(), entry.getTargetName(), entry.getDetail(),
                    entry.getCreatedAt());
        }
    }

    @GetMapping
    public List<AuditEventResponse> list(@RequestParam(required = false) Long projectId,
                                         @AuthenticationPrincipal Jwt jwt) {
        String tenantId = tenant(jwt);
        gate.requireFeature(jwt.getTokenValue(), "AUDIT_LOG", "the audit log");
        Integer historyDays = subscriptionInfoClient.historyDays(tenantId, jwt.getTokenValue());
        Instant since = historyDays == null ? Instant.EPOCH
                : Instant.now().minus(Duration.ofDays(historyDays));
        List<CoreAuditLog> rows = projectId == null
                ? auditLogRepository
                        .findTop200ByTenantIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
                                tenantId, since)
                : auditLogRepository
                        .findTop200ByTenantIdAndProjectIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
                                tenantId, projectId, since);
        return rows.stream().map(AuditEventResponse::from).toList();
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
