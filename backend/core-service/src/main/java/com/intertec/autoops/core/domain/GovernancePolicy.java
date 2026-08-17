package com.intertec.autoops.core.domain;

import java.util.Locale;

/**
 * The platform's governance policy catalog. Two kinds:
 * <ul>
 *   <li><b>Configurable</b> (stored per tenant, {@code governance_policies}):
 *       SCM_REQUIRED and FAILURE_BUDGET can be ENFORCED (blocking manual runs
 *       in violating projects), MONITOR or DISABLED; APPROVAL_SLA has nothing
 *       to block, so only MONITOR/DISABLED.</li>
 *   <li><b>Derived</b>: RISKY_APPROVAL mirrors the tenant's approval settings
 *       (risky-type gating) and CREDENTIAL_HYGIENE is enforced by design
 *       (disconnect purges credentials) — neither is stored nor settable.</li>
 * </ul>
 */
public enum GovernancePolicy {

    RISKY_APPROVAL("Risky operations require approval",
            "Workflows with risky or complex steps",
            false, false, null),
    SCM_REQUIRED("Definitions versioned in git",
            "All active projects",
            true, true, GovernancePolicyMode.MONITOR),
    CREDENTIAL_HYGIENE("Revoked integrations retain no credentials",
            "Cloud integrations",
            false, false, null),
    FAILURE_BUDGET("Run failure rate stays under 25% (30 days)",
            "All active projects",
            true, true, GovernancePolicyMode.MONITOR),
    APPROVAL_SLA("Approvals decided within 7 days",
            "Pending approval requests",
            true, false, GovernancePolicyMode.MONITOR);

    private final String label;
    private final String scope;
    private final boolean configurable;
    private final boolean supportsEnforced;
    private final GovernancePolicyMode defaultMode;

    GovernancePolicy(String label, String scope, boolean configurable,
                     boolean supportsEnforced, GovernancePolicyMode defaultMode) {
        this.label = label;
        this.scope = scope;
        this.configurable = configurable;
        this.supportsEnforced = supportsEnforced;
        this.defaultMode = defaultMode;
    }

    public String label() {
        return label;
    }

    public String scope() {
        return scope;
    }

    public boolean configurable() {
        return configurable;
    }

    public boolean supportsEnforced() {
        return supportsEnforced;
    }

    public GovernancePolicyMode defaultMode() {
        return defaultMode;
    }

    /** Null-safe, case-insensitive parse; null when unknown. */
    public static GovernancePolicy fromCode(String code) {
        if (code == null || code.isBlank()) {
            return null;
        }
        try {
            return GovernancePolicy.valueOf(code.trim().toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException ex) {
            return null;
        }
    }
}