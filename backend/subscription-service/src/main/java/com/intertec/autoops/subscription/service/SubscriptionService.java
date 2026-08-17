package com.intertec.autoops.subscription.service;

import com.intertec.autoops.subscription.config.SubscriptionProperties;
import com.intertec.autoops.subscription.domain.Payment;
import com.intertec.autoops.subscription.domain.PaymentStatus;
import com.intertec.autoops.subscription.domain.Plan;
import com.intertec.autoops.subscription.domain.PlanCode;
import com.intertec.autoops.subscription.domain.Subscription;
import com.intertec.autoops.subscription.domain.SubscriptionEventType;
import com.intertec.autoops.subscription.domain.SubscriptionStatus;
import com.intertec.autoops.subscription.exception.SubscriptionException;
import com.intertec.autoops.subscription.repo.PlanRepository;
import com.intertec.autoops.subscription.repo.SubscriptionRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Optional;

/**
 * Per-tenant subscription lifecycle with STUBBED billing: subscribing or
 * changing plans succeeds without charging. New subscriptions start TRIALING
 * for the plan's trial window; status transitions that depend on time
 * (trial expiry, canceled period ending) are applied lazily on read.
 */
@Service
public class SubscriptionService {

    private static final Logger log = LoggerFactory.getLogger(SubscriptionService.class);

    private final SubscriptionRepository subscriptionRepository;
    private final PlanRepository planRepository;
    private final SubscriptionProperties properties;
    private final EntitlementService entitlementService;
    private final AuditService auditService;
    private final PaymentService paymentService;

    public SubscriptionService(SubscriptionRepository subscriptionRepository,
                               PlanRepository planRepository,
                               SubscriptionProperties properties,
                               EntitlementService entitlementService,
                               AuditService auditService,
                               PaymentService paymentService) {
        this.subscriptionRepository = subscriptionRepository;
        this.planRepository = planRepository;
        this.properties = properties;
        this.entitlementService = entitlementService;
        this.auditService = auditService;
        this.paymentService = paymentService;
    }

    @Transactional(readOnly = true)
    public Optional<Subscription> findCurrent(String tenantId) {
        return subscriptionRepository.findByTenantId(tenantId).map(this::withEffectiveStatus);
    }

    /**
     * Creates or switches the tenant's subscription (stub billing: no charge).
     * First subscription => TRIALING; plan change keeps the current phase;
     * subscribing again after cancel/expiry reactivates as ACTIVE.
     *
     * @param actor JWT subject (email) of the admin acting — audit trail only
     */
    @Transactional
    public Subscription subscribe(String tenantId, PlanCode planCode, String actor) {
        Plan plan = planRepository.findByCode(planCode)
                .filter(Plan::isActive)
                .orElseThrow(() -> SubscriptionException.badRequest("unknown_plan",
                        "Unknown or inactive plan: " + planCode));

        Instant now = Instant.now();
        Subscription subscription = subscriptionRepository.findByTenantId(tenantId).orElse(null);
        SubscriptionEventType event;
        String detail;
        if (subscription == null) {
            subscription = new Subscription();
            subscription.setTenantId(tenantId);
            subscription.setStatus(SubscriptionStatus.TRIALING);
            subscription.setTrialEndsAt(now.plus(java.time.Duration.ofDays(plan.getTrialDays())));
            event = SubscriptionEventType.SUBSCRIBED;
            detail = plan.getTrialDays() + "-day trial";
            log.info("Tenant {} starts {}-day trial on {}", tenantId, plan.getTrialDays(), planCode);
        } else {
            PlanCode previousPlan = subscription.getPlan().getCode();
            SubscriptionStatus effective = effectiveStatus(subscription, now);
            if (effective == SubscriptionStatus.CANCELED || effective == SubscriptionStatus.EXPIRED) {
                subscription.setStatus(SubscriptionStatus.ACTIVE);
                subscription.setTrialEndsAt(null);
                event = SubscriptionEventType.REACTIVATED;
                detail = "was " + effective;
                log.info("Tenant {} reactivates on {}", tenantId, planCode);
            } else {
                // Plan change during trial/active keeps the phase (stub
                // billing: no proration to compute).
                event = SubscriptionEventType.PLAN_CHANGED;
                detail = previousPlan + " -> " + planCode;
            }
        }
        subscription.setPlan(plan);
        subscription.setCancelAtPeriodEnd(false);
        subscription.setCurrentPeriodStart(now);
        subscription.setCurrentPeriodEnd(now.plus(properties.getBillingPeriod()));
        Subscription saved = subscriptionRepository.save(subscription);
        entitlementService.evictTenant(tenantId);
        auditService.record(event, tenantId, planCode, actor, detail);

        // Trials are free; money changes hands on reactivation and on plan
        // changes outside the trial. A decline drops the subscription to
        // PAST_DUE (recover via POST /api/payments/retry) — the subscribe
        // call itself still succeeds so the caller sees the true state.
        boolean chargeable = event == SubscriptionEventType.REACTIVATED
                || (event == SubscriptionEventType.PLAN_CHANGED
                        && saved.getStatus() == SubscriptionStatus.ACTIVE);
        if (chargeable) {
            Payment payment = paymentService.chargeSubscription(saved, plan, actor);
            if (payment.getStatus() == PaymentStatus.FAILED) {
                saved.setStatus(SubscriptionStatus.PAST_DUE);
                saved = subscriptionRepository.save(saved);
                entitlementService.evictTenant(tenantId);
            }
        }
        return withEffectiveStatus(saved);
    }

    /** Cancels at period end — access continues until current_period_end. */
    @Transactional
    public Subscription cancel(String tenantId, String actor) {
        Subscription subscription = subscriptionRepository.findByTenantId(tenantId)
                .orElseThrow(() -> SubscriptionException.notFound("no_subscription",
                        "This workspace has no subscription"));
        subscription.setCancelAtPeriodEnd(true);
        Subscription saved = subscriptionRepository.save(subscription);
        entitlementService.evictTenant(tenantId);
        auditService.record(SubscriptionEventType.CANCELED, tenantId, saved.getPlan().getCode(),
                actor, "access until " + saved.getCurrentPeriodEnd());
        return withEffectiveStatus(saved);
    }

    // ------------------------------------------------------------------

    /**
     * Time-dependent transitions, computed on read (no scheduler needed for
     * stub billing): expired trial => EXPIRED; canceled-at-period-end past the
     * period => CANCELED.
     */
    SubscriptionStatus effectiveStatus(Subscription subscription, Instant now) {
        SubscriptionStatus status = subscription.getStatus();
        if (status == SubscriptionStatus.TRIALING
                && subscription.getTrialEndsAt() != null
                && now.isAfter(subscription.getTrialEndsAt())) {
            return SubscriptionStatus.EXPIRED;
        }
        if (subscription.isCancelAtPeriodEnd()
                && now.isAfter(subscription.getCurrentPeriodEnd())) {
            return SubscriptionStatus.CANCELED;
        }
        return status;
    }

    private Subscription withEffectiveStatus(Subscription subscription) {
        subscription.setStatus(effectiveStatus(subscription, Instant.now()));
        return subscription;
    }
}
