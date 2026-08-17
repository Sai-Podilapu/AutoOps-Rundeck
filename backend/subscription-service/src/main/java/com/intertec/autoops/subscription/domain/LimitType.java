package com.intertec.autoops.subscription.domain;

/**
 * Numeric plan quotas enforced through the central entitlement check: the
 * OWNING service counts its own resources and asks; this service decides
 * against the plan column. A {@code NULL} column value means unlimited.
 *
 * <p>Retention depth ({@code history_days}) is deliberately NOT a quota — it
 * is a read-time bound exposed via the plan payload, not a creation gate.
 */
public enum LimitType {
    /** plans.max_projects */
    MAX_PROJECTS,
    /** plans.max_nodes */
    MAX_NODES,
    /** plans.max_automations — automation workflows */
    MAX_AUTOMATIONS,
    /** plans.max_jobs */
    MAX_JOBS,
    /** plans.max_cloud_integrations — connected cloud accounts */
    MAX_CLOUD_INTEGRATIONS;

    /** Case-insensitive, null-safe parse (same convention as Feature.fromCode). */
    public static LimitType fromCode(String code) {
        if (code == null || code.isBlank()) {
            return null;
        }
        try {
            return valueOf(code.trim().toUpperCase(java.util.Locale.ROOT));
        } catch (IllegalArgumentException ex) {
            return null;
        }
    }

    /** The plan's ceiling for this limit; {@code null} = unlimited. */
    public Integer maxFor(Plan plan) {
        return switch (this) {
            case MAX_PROJECTS -> plan.getMaxProjects();
            case MAX_NODES -> plan.getMaxNodes();
            case MAX_AUTOMATIONS -> plan.getMaxAutomations();
            case MAX_JOBS -> plan.getMaxJobs();
            case MAX_CLOUD_INTEGRATIONS -> plan.getMaxCloudIntegrations();
        };
    }
}
