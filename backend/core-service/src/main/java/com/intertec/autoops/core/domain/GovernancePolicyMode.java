package com.intertec.autoops.core.domain;

import java.util.Locale;

/**
 * How a governance policy behaves: ENFORCED blocks violating manual runs,
 * MONITOR only reports violations, DISABLED skips the policy entirely.
 */
public enum GovernancePolicyMode {
    ENFORCED,
    MONITOR,
    DISABLED;

    /** Null-safe, case-insensitive parse; null when unknown. */
    public static GovernancePolicyMode fromCode(String code) {
        if (code == null || code.isBlank()) {
            return null;
        }
        try {
            return GovernancePolicyMode.valueOf(code.trim().toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException ex) {
            return null;
        }
    }
}