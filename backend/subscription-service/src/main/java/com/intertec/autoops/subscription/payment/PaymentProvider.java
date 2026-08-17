package com.intertec.autoops.subscription.payment;

import com.intertec.autoops.subscription.domain.PaymentProviderType;

/**
 * The seam a real billing provider plugs into. Adding Stripe = one bean
 * implementing this interface (wrapping PaymentIntents) + setting
 * {@code autoops.subscription.payment-provider: stripe} — PaymentService,
 * the API, and the subscription lifecycle do not change.
 *
 * <p>Synchronous by design for now; webhook-driven flows (3DS, async
 * capture, dunning) layer on top later without breaking this contract.
 */
public interface PaymentProvider {

    PaymentProviderType type();

    /** Attempts the charge; must NEVER throw for a decline — return failed(). */
    ChargeResult charge(ChargeRequest request);

    /** What the provider is asked to charge. Card/customer data stays provider-side. */
    record ChargeRequest(String tenantId, String planCode, int amountCents, String currency,
                         String description) {
    }

    record ChargeResult(boolean succeeded, String providerRef, String failureReason) {

        public static ChargeResult succeeded(String providerRef) {
            return new ChargeResult(true, providerRef, null);
        }

        public static ChargeResult failed(String failureReason) {
            return new ChargeResult(false, null, failureReason);
        }
    }
}
