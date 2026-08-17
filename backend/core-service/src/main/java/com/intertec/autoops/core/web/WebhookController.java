package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.domain.Webhook;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.AuditService;
import com.intertec.autoops.core.service.WebhookService;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.List;
import java.util.Map;

/**
 * Webhook management (authenticated) + the public fire endpoint
 * {@code POST /api/hooks/{token}} where the unguessable token is the sole
 * credential (permitAll in SecurityConfig; 404 on any miss so tokens can't
 * be probed apart from existence).
 */
@RestController
public class WebhookController {

    private final WebhookService webhookService;
    private final AuditService auditService;

    public WebhookController(WebhookService webhookService, AuditService auditService) {
        this.webhookService = webhookService;
        this.auditService = auditService;
    }

    public record WebhookRequest(@NotBlank @Size(max = 128) String name,
                                 @Size(max = 16) String targetType,
                                 @NotNull Long targetId) {
    }

    public record WebhookUpdateRequest(@Size(max = 128) String name,
                                       @Size(max = 16) String targetType,
                                       Long targetId, Boolean enabled) {
    }

    public record WebhookResponse(Long id, Long projectId, String name, String url,
                                  String targetType, Long targetId, boolean enabled,
                                  Instant lastFiredAt, String lastStatus,
                                  Instant createdAt) {

        static WebhookResponse from(Webhook webhook) {
            return new WebhookResponse(webhook.getId(), webhook.getProjectId(),
                    webhook.getName(), "/api/hooks/" + webhook.getToken(),
                    webhook.getTargetType().name(), webhook.getTargetId(),
                    webhook.isEnabled(), webhook.getLastFiredAt(),
                    webhook.getLastStatus(), webhook.getCreatedAt());
        }
    }

    @GetMapping("/api/webhooks")
    public List<WebhookResponse> list(@RequestParam(required = false) Long projectId,
                                      @AuthenticationPrincipal Jwt jwt) {
        return webhookService.list(tenant(jwt), projectId).stream()
                .map(WebhookResponse::from).toList();
    }

    @PostMapping("/api/webhooks")
    @ResponseStatus(HttpStatus.CREATED)
    public WebhookResponse create(@Valid @RequestBody WebhookRequest request,
                                  @AuthenticationPrincipal Jwt jwt) {
        Webhook webhook = webhookService.create(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), request.name(),
                request.targetType() == null ? "JOB" : request.targetType(),
                request.targetId());
        auditService.record(CoreAuditEventType.WEBHOOK_CREATED, tenant(jwt), jwt.getSubject(),
                webhook.getProjectId(), "WEBHOOK", webhook.getId(), webhook.getName(),
                webhook.getTargetType() + " " + webhook.getTargetId());
        return WebhookResponse.from(webhook);
    }

    @PutMapping("/api/webhooks/{id}")
    public WebhookResponse update(@PathVariable Long id,
                                  @RequestBody WebhookUpdateRequest request,
                                  @AuthenticationPrincipal Jwt jwt) {
        Webhook webhook = webhookService.update(tenant(jwt), jwt.getTokenValue(), id,
                request.name(), request.targetType(), request.targetId(), request.enabled());
        auditService.record(CoreAuditEventType.WEBHOOK_UPDATED, tenant(jwt), jwt.getSubject(),
                webhook.getProjectId(), "WEBHOOK", webhook.getId(), webhook.getName(), null);
        return WebhookResponse.from(webhook);
    }

    @DeleteMapping("/api/webhooks/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        webhookService.delete(tenant(jwt), jwt.getTokenValue(), id);
        auditService.record(CoreAuditEventType.WEBHOOK_DELETED, tenant(jwt), jwt.getSubject(),
                null, "WEBHOOK", id, null, null);
    }

    /** PUBLIC: external systems call this to start the bound job/workflow. */
    @PostMapping("/api/hooks/{token}")
    @ResponseStatus(HttpStatus.ACCEPTED)
    public Map<String, Object> fire(@PathVariable String token) {
        var run = webhookService.fire(token);
        // Deliberately minimal: callers get the run id, nothing tenant-shaped.
        return Map.of("accepted", true, "runId", run.getId());
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
