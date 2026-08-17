package com.intertec.autoops.subscription.web;

import com.intertec.autoops.subscription.domain.Plan;
import com.intertec.autoops.subscription.domain.PlanCode;
import com.intertec.autoops.subscription.domain.Subscription;
import com.intertec.autoops.subscription.domain.SubscriptionEventType;
import com.intertec.autoops.subscription.exception.SubscriptionException;
import com.intertec.autoops.subscription.repo.PaymentRepository;
import com.intertec.autoops.subscription.repo.PlanRepository;
import com.intertec.autoops.subscription.repo.SubscriptionAuditLogRepository;
import com.intertec.autoops.subscription.repo.SubscriptionRepository;
import com.intertec.autoops.subscription.service.AuditService;
import com.intertec.autoops.subscription.web.dto.PlanResponse;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Platform-operator surface over billing data — every endpoint requires the
 * PROVIDER role. Tenant subscriptions, cross-tenant payment history, billing
 * audit, and live plan-catalog administration (audited as PLAN_UPDATED;
 * entitlement caches expire within their 60s TTL).
 */
@RestController
@RequestMapping("/api/provider")
@PreAuthorize("hasRole('PROVIDER')")
public class ProviderController {

    private final SubscriptionRepository subscriptionRepository;
    private final PaymentRepository paymentRepository;
    private final PlanRepository planRepository;
    private final SubscriptionAuditLogRepository auditLogRepository;
    private final AuditService auditService;

    public ProviderController(SubscriptionRepository subscriptionRepository,
                              PaymentRepository paymentRepository,
                              PlanRepository planRepository,
                              SubscriptionAuditLogRepository auditLogRepository,
                              AuditService auditService) {
        this.subscriptionRepository = subscriptionRepository;
        this.paymentRepository = paymentRepository;
        this.planRepository = planRepository;
        this.auditLogRepository = auditLogRepository;
        this.auditService = auditService;
    }

    // ------ tenants: every subscription with its plan ------

    public record TenantSubscription(String tenantId, String planCode, String planName,
                                     int priceMonthly, String status, Instant trialEndsAt,
                                     Instant currentPeriodEnd, boolean cancelAtPeriodEnd,
                                     Instant createdAt) {
    }

    @GetMapping("/tenants")
    public List<TenantSubscription> tenants() {
        List<TenantSubscription> out = new ArrayList<>();
        for (Subscription subscription : subscriptionRepository.findAll()) {
            Plan plan = subscription.getPlan();
            out.add(new TenantSubscription(subscription.getTenantId(),
                    plan.getCode().name(), plan.getName(), plan.getPriceMonthly(),
                    subscription.getStatus().name(), subscription.getTrialEndsAt(),
                    subscription.getCurrentPeriodEnd(), subscription.isCancelAtPeriodEnd(),
                    subscription.getCreatedAt()));
        }
        return out;
    }

    // ------ payments: newest first, across every tenant ------

    public record ProviderPayment(Long id, String tenantId, String planCode, int amountCents,
                                  String currency, String status, String failureReason,
                                  Instant createdAt) {
    }

    @GetMapping("/payments")
    public List<ProviderPayment> payments() {
        return paymentRepository.findTop200ByOrderByCreatedAtDesc().stream()
                .map(p -> new ProviderPayment(p.getId(), p.getTenantId(),
                        p.getPlanCode() != null ? p.getPlanCode().name() : null,
                        p.getAmountCents(), p.getCurrency(), p.getStatus().name(),
                        p.getFailureReason(), p.getCreatedAt()))
                .toList();
    }

    // ------ billing audit: cross-tenant event trail ------

    public record ProviderAuditEvent(Long id, String eventType, String tenantId,
                                     String planCode, String actor, String detail,
                                     Instant createdAt) {
    }

    @GetMapping("/audit")
    public List<ProviderAuditEvent> audit() {
        return auditLogRepository.findTop200ByOrderByCreatedAtDesc().stream()
                .map(e -> new ProviderAuditEvent(e.getId(), e.getEventType().name(),
                        e.getTenantId(),
                        e.getPlanCode() != null ? e.getPlanCode().name() : null,
                        e.getActor(), e.getDetail(), e.getCreatedAt()))
                .toList();
    }

    // ------ plan administration: LIVE edits to the catalog ------

    public record PlanUpdateRequest(Integer priceMonthly, String description,
                                    Integer maxProjects, Integer maxAutomations,
                                    Integer maxNodes, Integer maxJobs,
                                    Integer maxCloudIntegrations, Integer historyDays,
                                    Boolean active) {
    }

    @PatchMapping("/plans/{code}")
    @Transactional
    public PlanResponse updatePlan(@PathVariable String code,
                                   @RequestBody PlanUpdateRequest request,
                                   @AuthenticationPrincipal Jwt jwt) {
        PlanCode planCode = PlanCode.fromCode(code.toUpperCase(Locale.ROOT));
        if (planCode == null) {
            throw SubscriptionException.badRequest("unknown_plan", "Unknown plan: " + code);
        }
        Plan plan = planRepository.findByCode(planCode)
                .orElseThrow(() -> SubscriptionException.badRequest("unknown_plan",
                        "Unknown plan: " + code));
        StringBuilder changes = new StringBuilder();
        if (request.priceMonthly() != null) {
            if (request.priceMonthly() < 0 || request.priceMonthly() > 100_000) {
                throw SubscriptionException.badRequest("invalid_price",
                        "Monthly price must be between 0 and 100000");
            }
            changes.append("price ").append(plan.getPriceMonthly()).append("->")
                    .append(request.priceMonthly()).append("; ");
            plan.setPriceMonthly(request.priceMonthly());
        }
        if (request.description() != null && !request.description().isBlank()) {
            plan.setDescription(request.description());
            changes.append("description; ");
        }
        applyLimit(request.maxProjects(), plan::setMaxProjects, "maxProjects", changes);
        applyLimit(request.maxAutomations(), plan::setMaxAutomations, "maxAutomations", changes);
        applyLimit(request.maxNodes(), plan::setMaxNodes, "maxNodes", changes);
        applyLimit(request.maxJobs(), plan::setMaxJobs, "maxJobs", changes);
        applyLimit(request.maxCloudIntegrations(), plan::setMaxCloudIntegrations,
                "maxCloudIntegrations", changes);
        applyLimit(request.historyDays(), plan::setHistoryDays, "historyDays", changes);
        if (request.active() != null) {
            plan.setActive(request.active());
            changes.append("active=").append(request.active()).append("; ");
        }
        if (changes.isEmpty()) {
            throw SubscriptionException.badRequest("nothing_to_update",
                    "No plan fields were supplied");
        }
        Plan saved = planRepository.save(plan);
        auditService.record(SubscriptionEventType.PLAN_UPDATED, "platform", planCode,
                jwt.getSubject(), changes.toString().trim());
        return PlanResponse.from(saved);
    }

    private void applyLimit(Integer value, java.util.function.Consumer<Integer> setter,
                            String label, StringBuilder changes) {
        if (value == null) {
            return;
        }
        if (value < 0 || value > 1_000_000) {
            throw SubscriptionException.badRequest("invalid_limit",
                    label + " must be between 0 and 1000000");
        }
        setter.accept(value);
        changes.append(label).append("=").append(value).append("; ");
    }
}
