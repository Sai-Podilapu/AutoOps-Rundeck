package com.intertec.autoops.auth.domain;

/** Mirrors MySQL ENUM('PENDING','SENT','DELIVERED','BOUNCED','FAILED') on otp_entries.delivery_status. */
public enum OtpDeliveryStatus {
    PENDING,
    SENT,
    DELIVERED,
    BOUNCED,
    FAILED
}
