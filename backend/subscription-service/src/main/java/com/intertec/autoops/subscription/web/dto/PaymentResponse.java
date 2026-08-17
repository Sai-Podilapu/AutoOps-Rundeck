package com.intertec.autoops.subscription.web.dto;

import com.intertec.autoops.subscription.domain.Payment;

import java.time.Instant;

public record PaymentResponse(
        Long id,
        String provider,
        String providerRef,
        String planCode,
        int amountCents,
        String currency,
        String status,
        String failureReason,
        Instant periodStart,
        Instant periodEnd,
        Instant createdAt) {

    public static PaymentResponse from(Payment payment) {
        return new PaymentResponse(payment.getId(), payment.getProvider().name(),
                payment.getProviderRef(), payment.getPlanCode().name(),
                payment.getAmountCents(), payment.getCurrency(), payment.getStatus().name(),
                payment.getFailureReason(), payment.getPeriodStart(), payment.getPeriodEnd(),
                payment.getCreatedAt());
    }
}
