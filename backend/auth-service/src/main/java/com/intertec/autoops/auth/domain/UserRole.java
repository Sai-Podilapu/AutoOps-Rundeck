package com.intertec.autoops.auth.domain;

/** Mirrors MySQL ENUM('PROVIDER','CLIENT','ADMIN','VIEWER') on users.role. */
public enum UserRole {
    PROVIDER,
    CLIENT,
    ADMIN,
    /** Read-only member — core-service denies every mutating request. */
    VIEWER
}
