package com.intertec.autoops.core.service;

import com.intertec.autoops.core.client.EntitlementClient;
import com.intertec.autoops.core.client.WorkflowClient;
import com.intertec.autoops.core.domain.Run;
import com.intertec.autoops.core.domain.RunTargetType;
import com.intertec.autoops.core.domain.Webhook;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.JobRepository;
import com.intertec.autoops.core.repo.WebhookRepository;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.security.SecureRandom;
import java.time.Instant;
import java.util.Base64;
import java.util.List;
import java.util.Locale;

/**
 * Inbound trigger URLs. Creating one mints an unguessable token; POST
 * /api/hooks/{token} (public, token IS the credential) starts the bound job
 * or workflow. Fires are entitlement-checked through the tenant-scoped
 * internal endpoint (no user token exists — same rule as the scheduler) and
 * skip the approval gate like other machine triggers.
 */
@Service
public class WebhookService {

    private static final Logger log = LoggerFactory.getLogger(WebhookService.class);
    private static final SecureRandom RANDOM = new SecureRandom();

    private final WebhookRepository webhookRepository;
    private final JobRepository jobRepository;
    private final WorkflowClient workflowClient;
    private final RunService runService;
    private final SubscriptionGate gate;
    private final EntitlementClient entitlementClient;
    /** Nullable: slice tests have no MeterRegistry. */
    private final MeterRegistry meterRegistry;

    public WebhookService(WebhookRepository webhookRepository, JobRepository jobRepository,
                          WorkflowClient workflowClient, RunService runService,
                          SubscriptionGate gate, EntitlementClient entitlementClient,
                          ObjectProvider<MeterRegistry> meterRegistry) {
        this.webhookRepository = webhookRepository;
        this.jobRepository = jobRepository;
        this.workflowClient = workflowClient;
        this.runService = runService;
        this.gate = gate;
        this.entitlementClient = entitlementClient;
        this.meterRegistry = meterRegistry.getIfAvailable();
    }

    @Transactional(readOnly = true)
    public List<Webhook> list(String tenantId, Long projectId) {
        return projectId != null
                ? webhookRepository.findByTenantIdAndProjectIdOrderByCreatedAtDesc(tenantId, projectId)
                : webhookRepository.findByTenantIdOrderByCreatedAtDesc(tenantId);
    }

    @Transactional
    public Webhook create(String tenantId, String actor, String accessToken,
                          String name, String targetTypeCode, Long targetId) {
        gate.requireActive(accessToken);
        RunTargetType targetType = parseTargetType(targetTypeCode);
        Long projectId = resolveProject(tenantId, targetType, targetId);
        Webhook webhook = new Webhook();
        webhook.setTenantId(tenantId);
        webhook.setProjectId(projectId);
        webhook.setName(name);
        webhook.setTargetType(targetType);
        webhook.setTargetId(targetId);
        webhook.setToken(newToken());
        webhook.setCreatedBy(actor);
        Webhook saved = webhookRepository.save(webhook);
        log.info("Tenant {} created webhook {} -> {} {}", tenantId, saved.getId(),
                targetType, targetId);
        return saved;
    }

    /** Null fields = unchanged; enabled toggles pause the trigger URL. */
    @Transactional
    public Webhook update(String tenantId, String accessToken, Long id,
                          String name, String targetTypeCode, Long targetId, Boolean enabled) {
        gate.requireActive(accessToken);
        Webhook webhook = require(tenantId, id);
        if (name != null && !name.isBlank()) {
            webhook.setName(name);
        }
        if (targetTypeCode != null || targetId != null) {
            RunTargetType targetType = targetTypeCode != null
                    ? parseTargetType(targetTypeCode) : webhook.getTargetType();
            Long target = targetId != null ? targetId : webhook.getTargetId();
            webhook.setProjectId(resolveProject(tenantId, targetType, target));
            webhook.setTargetType(targetType);
            webhook.setTargetId(target);
        }
        if (enabled != null) {
            webhook.setEnabled(enabled);
        }
        return webhookRepository.save(webhook);
    }

    @Transactional
    public void delete(String tenantId, String accessToken, Long id) {
        gate.requireActive(accessToken);
        webhookRepository.delete(require(tenantId, id));
    }

    /**
     * The public fire path: token is the sole credential. 404 on any miss.
     * noRollbackFor: a denial throws 403 but the denied-stamp on the webhook
     * row must survive (same precedent as auth's reuse-revocation).
     */
    @Transactional(noRollbackFor = CoreException.class)
    public Run fire(String token) {
        Webhook webhook = webhookRepository.findByToken(token)
                .filter(Webhook::isEnabled)
                .orElseThrow(() -> CoreException.notFound("hook_not_found",
                        "Unknown or disabled trigger"));
        EntitlementClient.Decision decision =
                entitlementClient.checkTenant(webhook.getTenantId());
        // Same asymmetry as the scheduler: an entitlement OUTAGE lets the
        // trigger through (loudly); a real denial blocks it.
        if (!decision.entitled()
                && !EntitlementClient.UNAVAILABLE.equals(decision.reason())) {
            stamp(webhook, "denied:" + decision.reason());
            count("denied");
            throw CoreException.forbidden(decision.reason(),
                    "The workspace subscription does not allow runs right now");
        }
        Run run;
        if (webhook.getTargetType() == RunTargetType.WORKFLOW) {
            var workflow = workflowClient
                    .find(webhook.getTenantId(), webhook.getTargetId())
                    .orElseThrow(() -> CoreException.notFound("hook_target_missing",
                            "The bound workflow no longer exists"));
            run = runService.runFromWebhook(workflow, webhook.getName());
        } else {
            var job = jobRepository
                    .findByIdAndTenantId(webhook.getTargetId(), webhook.getTenantId())
                    .orElseThrow(() -> CoreException.notFound("hook_target_missing",
                            "The bound job no longer exists"));
            run = runService.runFromWebhook(job, webhook.getName());
        }
        stamp(webhook, "accepted");
        count("accepted");
        log.info("Webhook {} fired -> run {}", webhook.getId(), run.getId());
        return run;
    }

    private void stamp(Webhook webhook, String status) {
        webhook.setLastFiredAt(Instant.now());
        webhook.setLastStatus(status.length() > 32 ? status.substring(0, 32) : status);
        webhookRepository.save(webhook);
    }

    private void count(String outcome) {
        if (meterRegistry != null) {
            meterRegistry.counter("core_webhook_fires_total", "outcome", outcome).increment();
        }
    }

    private Long resolveProject(String tenantId, RunTargetType targetType, Long targetId) {
        if (targetType == RunTargetType.WORKFLOW) {
            return workflowClient.require(tenantId, targetId).projectId();
        }
        return jobRepository.findByIdAndTenantId(targetId, tenantId)
                .orElseThrow(() -> CoreException.notFound("job_not_found", "No such job"))
                .getProject().getId();
    }

    private Webhook require(String tenantId, Long id) {
        return webhookRepository.findByIdAndTenantId(id, tenantId)
                .orElseThrow(() -> CoreException.notFound("webhook_not_found",
                        "No such webhook"));
    }

    private static RunTargetType parseTargetType(String code) {
        try {
            return RunTargetType.valueOf(code.trim().toUpperCase(Locale.ROOT));
        } catch (Exception ex) {
            throw CoreException.badRequest("unknown_target_type",
                    "Webhook target must be job or workflow");
        }
    }

    /** 32 random bytes, urlsafe — 43 chars, unguessable. */
    private static String newToken() {
        byte[] bytes = new byte[32];
        RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }
}
