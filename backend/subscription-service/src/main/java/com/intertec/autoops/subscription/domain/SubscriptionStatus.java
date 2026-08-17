package com.intertec.autoops.subscription.domain;

/** Mirrors MySQL ENUM on subscriptions.status. */
public enum SubscriptionStatus {
    TRIALING,
    ACTIVE,
    PAST_DUE,
    CANCELED,
    EXPIRED
}
