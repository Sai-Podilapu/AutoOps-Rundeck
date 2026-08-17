package com.intertec.autoops.subscription.domain;

import java.util.Locale;

/** Mirrors MySQL ENUM on plans.code. */
public enum PlanCode {
    STARTER,
    TEAM,
    BUSINESS,
    ENTERPRISE;

    /** Null-safe, case-insensitive parse; null when unknown. */
    public static PlanCode fromCode(String code) {
        if (code == null || code.isBlank()) {
            return null;
        }
        try {
            return PlanCode.valueOf(code.trim().toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException ex) {
            return null;
        }
    }
}
