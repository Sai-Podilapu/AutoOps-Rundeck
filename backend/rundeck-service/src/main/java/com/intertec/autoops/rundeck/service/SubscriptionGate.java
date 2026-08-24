package com.intertec.autoops.rundeck.service;

import com.intertec.autoops.rundeck.client.EntitlementClient;
import com.intertec.autoops.rundeck.exception.RundeckException;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Component;

/**
 * Turns entitlement decisions into HTTP errors — the single choke point every
 * mutation goes through, with the same error codes core-service returns
 * ({@code trial_expired}, {@code quota_exceeded}, ...) so the console's upgrade
 * prompts keep working unchanged.
 *
 * <p>Every gate outcome increments {@code rundeck_gate_checks_total}
 * (tags {@code allowed}, {@code reason}).
 */
@Component
public class SubscriptionGate {

    /**
     * A Rundeck connection is a cloud integration in every sense that matters
     * to a plan: it is an external system this workspace can drive. It shares
     * MAX_CLOUD_INTEGRATIONS rather than inventing a limit no plan row has a
     * value for — an unknown limit is treated as unlimited by
     * subscription-service, which would make the quota decorative.
     */
    public static final String CONNECTION_LIMIT = "MAX_CLOUD_INTEGRATIONS";

    private final EntitlementClient entitlementClient;
    /** Nullable: slice tests have no MeterRegistry; prod wires Prometheus. */
    private final MeterRegistry meterRegistry;

    public SubscriptionGate(EntitlementClient entitlementClient,
                            ObjectProvider<MeterRegistry> meterRegistry) {
        this.entitlementClient = entitlementClient;
        this.meterRegistry = meterRegistry.getIfAvailable();
    }

    /** Requires a live subscription. */
    public void requireActive(String accessToken) {
        enforce(entitlementClient.checkActive(accessToken), null);
    }

    /** Requires a live subscription AND a free quota slot. */
    public void requireQuota(String accessToken, String limit, long current, String resourceLabel) {
        enforce(entitlementClient.checkQuota(accessToken, limit, current), resourceLabel);
    }

    private void enforce(EntitlementClient.Decision decision, String resourceLabel) {
        count(decision);
        if (decision.entitled()) {
            return;
        }
        if (EntitlementClient.UNAVAILABLE.equals(decision.reason())) {
            throw RundeckException.serviceUnavailable(EntitlementClient.UNAVAILABLE,
                    "Subscription check is temporarily unavailable — please retry");
        }
        if ("quota_exceeded".equals(decision.reason())) {
            throw RundeckException.forbidden("quota_exceeded",
                    "Plan limit reached" + (decision.max() != null
                            ? " (" + decision.max() + " " + resourceLabel + ")" : "")
                            + " — upgrade your plan to add more");
        }
        if ("feature_not_in_plan".equals(decision.reason())) {
            throw RundeckException.forbidden("feature_not_in_plan",
                    "Your plan does not include "
                            + (resourceLabel != null ? resourceLabel : "this feature")
                            + " — upgrade to unlock it");
        }
        throw RundeckException.forbidden(decision.reason(),
                "Your subscription does not allow this operation (" + decision.reason() + ")");
    }

    private void count(EntitlementClient.Decision decision) {
        if (meterRegistry != null) {
            meterRegistry.counter("rundeck_gate_checks_total",
                    "allowed", String.valueOf(decision.entitled()),
                    "reason", decision.reason()).increment();
        }
    }
}
