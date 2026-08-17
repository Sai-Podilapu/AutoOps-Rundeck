package com.intertec.autoops.auth.domain;

/** Mirrors MySQL ENUM('ACTIVE','PENDING','DISABLED') on users.status. */
public enum UserStatus {
    ACTIVE,
    PENDING,
    DISABLED
}
