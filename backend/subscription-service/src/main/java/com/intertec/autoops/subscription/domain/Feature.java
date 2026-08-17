package com.intertec.autoops.subscription.domain;

import java.util.Locale;

/**
 * Platform features a plan can grant. Mirrors MySQL ENUM on plan_features.feature
 * and the frontend tier matrix (saasData.js).
 */
public enum Feature {
    CORE_AUTOMATION,
    PREMIUM_TEMPLATES,
    PRIVATE_TEMPLATES,
    SSO,
    ADVANCED_RBAC,
    AUDIT_LOG,
    API_ACCESS,
    COMPLIANCE_REPORTS,
    GOVERNANCE;

    /** Null-safe, case-insensitive parse; null when unknown. */
    public static Feature fromCode(String code) {
        if (code == null || code.isBlank()) {
            return null;
        }
        try {
            return Feature.valueOf(code.trim().toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException ex) {
            return null;
        }
    }
}
