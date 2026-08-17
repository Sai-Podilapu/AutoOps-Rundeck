package com.intertec.autoops.subscription.domain;

/**
 * Billing lifecycle events recorded in {@code subscription_audit_log} and
 * counted in the {@code subscription_events_total} Prometheus metric.
 * Extending = Flyway {@code ALTER ... MODIFY} + a constant here (type policy).
 */
public enum SubscriptionEventType {
    /** A tenant's very first subscription (trial start). */
    SUBSCRIBED,
    /** Plan switched while the subscription stayed in its current phase. */
    PLAN_CHANGED,
    /** Subscribe after cancel/expiry brought the tenant back to ACTIVE. */
    REACTIVATED,
    /** Cancel requested — access runs until the period end. */
    CANCELED,
    /** A charge went through (see the payments table for the record). */
    PAYMENT_SUCCEEDED,
    /** A charge was declined — the subscription drops to PAST_DUE. */
    PAYMENT_FAILED,
    /** A PROVIDER edited the plan catalog (pricing/limits/availability). */
    PLAN_UPDATED
}
