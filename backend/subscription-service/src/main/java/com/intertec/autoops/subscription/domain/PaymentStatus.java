package com.intertec.autoops.subscription.domain;

/** Charge attempt outcomes; a retry is a NEW payment row, never a mutation. */
public enum PaymentStatus {
    PENDING,
    SUCCEEDED,
    FAILED,
    REFUNDED
}
