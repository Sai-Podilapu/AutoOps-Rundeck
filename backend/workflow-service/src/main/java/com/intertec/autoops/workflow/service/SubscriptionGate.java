package com.intertec.autoops.workflow.service;

import com.intertec.autoops.workflow.client.EntitlementClient;
import com.intertec.autoops.workflow.exception.WorkflowException;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Component;

/**
 * Turns entitlement decisions into HTTP errors — the single choke point every
 * mutation goes through, with the same error codes core-service returns
 * ({@code trial_expired}, {@code quota_exceeded}, ...) so the console's
 * upgrade prompts keep working unchanged across the split.
 *
 * <p>Every gate outcome increments {@code workflow_gate_checks_total}
 * (tags {@code allowed}, {@code reason}).
 */
@Component
public class SubscriptionGate {

    private final EntitlementClient entitlementClient;
    /** Nullable: slice tests have no MeterRegistry; prod wires Prometheus. */
    private final MeterRegistry meterRegistry;

    public SubscriptionGate(EntitlementClient entitlementClient,
                            ObjectProvider<MeterRegistry> meterRegistry) {
        this.entitlementClient = entitlementClient;
        this.meterRegistry = meterRegistry.getIfAvailable();
    }

    /** Requires a live subscription (PAID/TRIALING in business vocabulary). */
    public void requireActive(String accessToken) {
        enforce(entitlementClient.checkActive(accessToken), null);
    }

    /** Requires a live subscription AND a free quota slot. */
    public void requireQuota(String accessToken, String limit, long current, String resourceLabel) {
        enforce(entitlementClient.checkQuota(accessToken, limit, current), resourceLabel);
    }

    /**
     * MAX_NODES bounds a workflow's SIZE, not a count of creations: a
     * definition with N nodes is allowed iff N <= max. The central contract
     * is "current < max allows one more", so ask with current = N - 1.
     */
    public void requireNodeCapacity(String accessToken, int nodeCount) {
        if (nodeCount == 0) {
            requireActive(accessToken);
            return;
        }
        enforce(entitlementClient.checkQuota(accessToken, "MAX_NODES", nodeCount - 1L),
                "nodes per workflow");
    }

    private void enforce(EntitlementClient.Decision decision, String resourceLabel) {
        count(decision);
        if (decision.entitled()) {
            return;
        }
        if (EntitlementClient.UNAVAILABLE.equals(decision.reason())) {
            throw WorkflowException.serviceUnavailable(EntitlementClient.UNAVAILABLE,
                    "Subscription check is temporarily unavailable — please retry");
        }
        if ("quota_exceeded".equals(decision.reason())) {
            throw WorkflowException.forbidden("quota_exceeded",
                    "Plan limit reached" + (decision.max() != null
                            ? " (" + decision.max() + " " + resourceLabel + ")" : "")
                            + " — upgrade your plan to add more");
        }
        if ("feature_not_in_plan".equals(decision.reason())) {
            throw WorkflowException.forbidden("feature_not_in_plan",
                    "Your plan does not include "
                            + (resourceLabel != null ? resourceLabel : "this feature")
                            + " — upgrade to unlock it");
        }
        throw WorkflowException.forbidden(decision.reason(),
                "Your subscription does not allow this operation (" + decision.reason() + ")");
    }

    private void count(EntitlementClient.Decision decision) {
        if (meterRegistry != null) {
            meterRegistry.counter("workflow_gate_checks_total",
                    "allowed", String.valueOf(decision.entitled()),
                    "reason", decision.reason()).increment();
        }
    }
}
