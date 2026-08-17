package com.intertec.autoops.subscription.web.dto;

import com.fasterxml.jackson.annotation.JsonInclude;

/**
 * Shape expected by auth-service's SubscriptionServiceClient (which reads a
 * Map — extra fields are ignored). max/remaining appear only on quota checks;
 * {@code max == null} on an entitled quota answer means unlimited.
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record EntitlementCheckResponse(boolean entitled, String reason, Integer max, Long remaining) {

    /** Feature-only answer (no quota fields). */
    public EntitlementCheckResponse(boolean entitled, String reason) {
        this(entitled, reason, null, null);
    }
}
