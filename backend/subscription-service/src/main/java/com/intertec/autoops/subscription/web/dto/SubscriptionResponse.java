package com.intertec.autoops.subscription.web.dto;

import com.intertec.autoops.subscription.domain.Subscription;

import java.time.Instant;

public record SubscriptionResponse(
        String tenantId,
        PlanResponse plan,
        String status,
        Instant trialEndsAt,
        Instant currentPeriodStart,
        Instant currentPeriodEnd,
        boolean cancelAtPeriodEnd) {

    public static SubscriptionResponse from(Subscription subscription) {
        return new SubscriptionResponse(
                subscription.getTenantId(),
                PlanResponse.from(subscription.getPlan()),
                subscription.getStatus().name(),
                subscription.getTrialEndsAt(),
                subscription.getCurrentPeriodStart(),
                subscription.getCurrentPeriodEnd(),
                subscription.isCancelAtPeriodEnd());
    }
}
