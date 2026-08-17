package com.intertec.autoops.subscription.web.dto;

/**
 * feature is optional: absent => "does this tenant have ANY live subscription";
 * present => "does the tenant's plan include this feature".
 *
 * <p>quota is optional: the OWNING service sends its current resource count
 * and this service compares it against the plan's ceiling (e.g.
 * {@code {"quota": {"limit": "MAX_PROJECTS", "current": 3}}}). When both
 * feature and quota are present, the feature gate is evaluated first.
 */
public record EntitlementCheckRequest(String feature, QuotaCheck quota) {

    /** current = how many the tenant has NOW, before creating another. */
    public record QuotaCheck(String limit, Long current) {
    }
}
