package com.intertec.autoops.subscription.service;

import com.intertec.autoops.subscription.config.SubscriptionProperties;
import com.intertec.autoops.subscription.domain.Payment;
import com.intertec.autoops.subscription.domain.PaymentStatus;
import com.intertec.autoops.subscription.domain.Plan;
import com.intertec.autoops.subscription.domain.Subscription;
import com.intertec.autoops.subscription.domain.SubscriptionEventType;
import com.intertec.autoops.subscription.domain.SubscriptionStatus;
import com.intertec.autoops.subscription.exception.SubscriptionException;
import com.intertec.autoops.subscription.payment.PaymentProvider;
import com.intertec.autoops.subscription.repo.PaymentRepository;
import com.intertec.autoops.subscription.repo.SubscriptionRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * Provider-agnostic charging. One immutable payments row per attempt; a
 * decline never throws — it is a FAILED row plus a PAST_DUE subscription,
 * recovered via {@link #retryLatestFailed}. The active provider is chosen by
 * {@code autoops.subscription.payment-provider} (stub today, stripe later).
 */
@Service
public class PaymentService {

    private static final Logger log = LoggerFactory.getLogger(PaymentService.class);

    private final PaymentRepository paymentRepository;
    private final SubscriptionRepository subscriptionRepository;
    private final Map<String, PaymentProvider> providers;
    private final SubscriptionProperties properties;
    private final EntitlementService entitlementService;
    private final AuditService auditService;

    public PaymentService(PaymentRepository paymentRepository,
                          SubscriptionRepository subscriptionRepository,
                          List<PaymentProvider> providerBeans,
                          SubscriptionProperties properties,
                          EntitlementService entitlementService,
                          AuditService auditService) {
        this.paymentRepository = paymentRepository;
        this.subscriptionRepository = subscriptionRepository;
        this.providers = providerBeans.stream().collect(Collectors.toMap(
                p -> p.type().name().toLowerCase(Locale.ROOT), Function.identity()));
        this.properties = properties;
        this.entitlementService = entitlementService;
        this.auditService = auditService;
    }

    @Transactional(readOnly = true)
    public List<Payment> history(String tenantId) {
        return paymentRepository.findByTenantIdOrderByCreatedAtDesc(tenantId);
    }

    /**
     * Charges the plan's monthly price for the subscription's current period.
     * Returns the recorded payment — the CALLER decides what a failure does
     * to the subscription (SubscriptionService drops it to PAST_DUE).
     */
    @Transactional
    public Payment chargeSubscription(Subscription subscription, Plan plan, String actor) {
        PaymentProvider provider = activeProvider();
        Payment payment = new Payment();
        payment.setTenantId(subscription.getTenantId());
        payment.setSubscriptionId(subscription.getId());
        payment.setProvider(provider.type());
        payment.setPlanCode(plan.getCode());
        payment.setAmountCents(plan.getPriceMonthly() * 100);
        payment.setCurrency("USD");
        payment.setPeriodStart(subscription.getCurrentPeriodStart());
        payment.setPeriodEnd(subscription.getCurrentPeriodEnd());

        PaymentProvider.ChargeResult result = provider.charge(new PaymentProvider.ChargeRequest(
                subscription.getTenantId(), plan.getCode().name(), payment.getAmountCents(),
                payment.getCurrency(), "AutoOps " + plan.getName() + " (monthly)"));
        if (result.succeeded()) {
            payment.setStatus(PaymentStatus.SUCCEEDED);
            payment.setProviderRef(result.providerRef());
            log.info("Tenant {} charged {} {} for {}", subscription.getTenantId(),
                    payment.getAmountCents(), payment.getCurrency(), plan.getCode());
        } else {
            payment.setStatus(PaymentStatus.FAILED);
            payment.setFailureReason(result.failureReason());
            log.warn("Tenant {} charge DECLINED for {}: {}", subscription.getTenantId(),
                    plan.getCode(), result.failureReason());
        }
        Payment saved = paymentRepository.save(payment);
        auditService.record(result.succeeded()
                        ? SubscriptionEventType.PAYMENT_SUCCEEDED
                        : SubscriptionEventType.PAYMENT_FAILED,
                subscription.getTenantId(), plan.getCode(), actor,
                (payment.getAmountCents() / 100) + " USD via " + provider.type()
                        + (result.succeeded() ? "" : ": " + result.failureReason()));
        return saved;
    }

    /**
     * Retries the tenant's most recent FAILED charge as a NEW payment row.
     * Success lifts the subscription out of PAST_DUE back to ACTIVE.
     */
    @Transactional
    public Payment retryLatestFailed(String tenantId, String actor) {
        Payment failed = paymentRepository
                .findTopByTenantIdAndStatusOrderByCreatedAtDesc(tenantId, PaymentStatus.FAILED)
                .orElseThrow(() -> SubscriptionException.notFound("no_failed_payment",
                        "There is no failed payment to retry"));
        Subscription subscription = subscriptionRepository.findByTenantId(tenantId)
                .orElseThrow(() -> SubscriptionException.notFound("no_subscription",
                        "This workspace has no subscription"));

        PaymentProvider provider = activeProvider();
        Payment retry = new Payment();
        retry.setTenantId(tenantId);
        retry.setSubscriptionId(failed.getSubscriptionId());
        retry.setProvider(provider.type());
        retry.setPlanCode(failed.getPlanCode());
        retry.setAmountCents(failed.getAmountCents());
        retry.setCurrency(failed.getCurrency());
        retry.setPeriodStart(failed.getPeriodStart());
        retry.setPeriodEnd(failed.getPeriodEnd());

        PaymentProvider.ChargeResult result = provider.charge(new PaymentProvider.ChargeRequest(
                tenantId, failed.getPlanCode().name(), retry.getAmountCents(),
                retry.getCurrency(), "AutoOps retry (" + failed.getPlanCode() + ")"));
        if (result.succeeded()) {
            retry.setStatus(PaymentStatus.SUCCEEDED);
            retry.setProviderRef(result.providerRef());
            if (subscription.getStatus() == SubscriptionStatus.PAST_DUE) {
                subscription.setStatus(SubscriptionStatus.ACTIVE);
                subscriptionRepository.save(subscription);
                entitlementService.evictTenant(tenantId);
            }
        } else {
            retry.setStatus(PaymentStatus.FAILED);
            retry.setFailureReason(result.failureReason());
        }
        Payment saved = paymentRepository.save(retry);
        auditService.record(result.succeeded()
                        ? SubscriptionEventType.PAYMENT_SUCCEEDED
                        : SubscriptionEventType.PAYMENT_FAILED,
                tenantId, failed.getPlanCode(), actor, "retry of payment " + failed.getId());
        return saved;
    }

    private PaymentProvider activeProvider() {
        PaymentProvider provider = providers.get(
                properties.getPaymentProvider().toLowerCase(Locale.ROOT));
        if (provider == null) {
            throw SubscriptionException.serviceUnavailable("payment_provider_missing",
                    "No PaymentProvider named '" + properties.getPaymentProvider() + "' is configured");
        }
        return provider;
    }
}
