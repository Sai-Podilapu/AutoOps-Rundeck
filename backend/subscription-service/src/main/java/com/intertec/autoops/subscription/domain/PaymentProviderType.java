package com.intertec.autoops.subscription.domain;

/**
 * Which PaymentProvider implementation charged. Adding a provider (e.g.
 * STRIPE) = Flyway {@code ALTER ... MODIFY} + a constant here + a bean
 * implementing PaymentProvider — nothing else changes.
 */
public enum PaymentProviderType {
    STUB,
    STRIPE
}
