package com.intertec.autoops.subscription.payment;

import com.intertec.autoops.subscription.config.SubscriptionProperties;
import com.intertec.autoops.subscription.domain.PaymentProviderType;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * No-charge development provider: every charge succeeds instantly with a
 * synthetic reference. Set {@code autoops.subscription.payment-stub-fails=true}
 * to make it decline everything — the only way to exercise the PAST_DUE /
 * retry path before a real provider exists.
 */
@Component
public class StubPaymentProvider implements PaymentProvider {

    private final SubscriptionProperties properties;

    public StubPaymentProvider(SubscriptionProperties properties) {
        this.properties = properties;
    }

    @Override
    public PaymentProviderType type() {
        return PaymentProviderType.STUB;
    }

    @Override
    public ChargeResult charge(ChargeRequest request) {
        if (properties.isPaymentStubFails()) {
            return ChargeResult.failed("stub provider configured to decline");
        }
        return ChargeResult.succeeded("stub-" + UUID.randomUUID());
    }
}
