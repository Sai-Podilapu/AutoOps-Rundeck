package com.intertec.autoops.core.client;

import com.intertec.autoops.core.config.CoreProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpHeaders;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.util.HashMap;
import java.util.Map;

/**
 * The subscription gate every MUTATION passes through: asks subscription-
 * service whether the tenant's subscription allows the operation. The tenant
 * is never sent — subscription-service reads it from the END USER's bearer
 * token, so this service can only ever ask about the caller's own tenant.
 *
 * <p>Status mapping (business vocabulary → decision reason):
 * PAID = ACTIVE/TRIALING → allowed; PENDING = PAST_DUE → denied
 * ({@code subscription_past_due}); CANCELLED → allowed until period end, then
 * denied ({@code subscription_canceled}); REVOKED = EXPIRED/expired trial →
 * denied ({@code subscription_expired}/{@code trial_expired}).
 *
 * <p><strong>FAIL-CLOSED</strong> by default when subscription-service is
 * unreachable; set ENTITLEMENT_FAIL_OPEN=true to allow mutations during
 * outages instead. Reads never pass through here — a tenant can always see
 * and export its own data.
 */
@Component
public class EntitlementClient {

    private static final Logger log = LoggerFactory.getLogger(EntitlementClient.class);

    /** Reason used when the decision could not be obtained at all. */
    public static final String UNAVAILABLE = "entitlement_unavailable";

    private final RestClient subscriptionRestClient;
    private final CoreProperties properties;

    public EntitlementClient(@Qualifier("subscriptionRestClient") RestClient subscriptionRestClient,
                             CoreProperties properties) {
        this.subscriptionRestClient = subscriptionRestClient;
        this.properties = properties;
    }

    /** max is null when the decision carries no quota (status-only or unlimited). */
    public record Decision(boolean entitled, String reason, Integer max, Long remaining) {
    }

    /** Status-only gate: is the tenant's subscription live at all? */
    public Decision checkActive(String accessToken) {
        return check(accessToken, null, null, null);
    }

    /** Feature gate: live subscription AND the plan grants {@code feature}. */
    public Decision checkFeature(String accessToken, String feature) {
        return check(accessToken, feature, null, null);
    }

    /**
     * Quota gate: {@code current} is this service's own count of the resource,
     * taken BEFORE creating another (allowed iff {@code current < max}).
     */
    public Decision checkQuota(String accessToken, String limit, long current) {
        return check(accessToken, null, limit, current);
    }

    /**
     * Tenant-scoped status gate for callers with NO user token — the cron
     * scheduler. Uses subscription-service's shared-secret {@code /internal}
     * endpoint instead of a bearer. Same Decision vocabulary as the public
     * checks.
     */
    public Decision checkTenant(String tenantId) {
        try {
            Map<String, Object> response = subscriptionRestClient.post()
                    .uri("/internal/entitlements/check")
                    .header("X-Internal-Token",
                            properties.getSubscription().getInternalToken())
                    .body(Map.of("tenantId", tenantId))
                    .retrieve()
                    .body(new ParameterizedTypeReference<Map<String, Object>>() {
                    });
            if (response == null) {
                return failDecision("empty internal entitlement response");
            }
            boolean entitled = Boolean.TRUE.equals(response.get("entitled"));
            String reason = response.get("reason") != null ? response.get("reason").toString() : "";
            return new Decision(entitled, reason, null, null);
        } catch (Exception ex) {
            log.warn("Internal entitlement check failed for tenant {}: {}", tenantId,
                    ex.getMessage());
            return failDecision(ex.getMessage());
        }
    }

    private Decision check(String accessToken, String feature, String limit, Long current) {
        try {
            Map<String, Object> body = new HashMap<>();
            if (feature != null) {
                body.put("feature", feature);
            }
            if (limit != null) {
                body.put("quota", Map.of("limit", limit, "current", current));
            }
            Map<String, Object> response = subscriptionRestClient.post()
                    .uri("/api/entitlements/check")
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                    .body(body)
                    .retrieve()
                    .body(new ParameterizedTypeReference<Map<String, Object>>() {
                    });
            if (response == null) {
                return failDecision("empty entitlement response");
            }
            boolean entitled = Boolean.TRUE.equals(response.get("entitled"));
            String reason = response.get("reason") != null ? response.get("reason").toString() : "";
            Integer max = response.get("max") instanceof Number n ? n.intValue() : null;
            Long remaining = response.get("remaining") instanceof Number n ? n.longValue() : null;
            return new Decision(entitled, reason, max, remaining);
        } catch (Exception ex) {
            log.warn("Entitlement check failed (limit={}): {}", limit, ex.getMessage());
            return failDecision(ex.getMessage());
        }
    }

    private Decision failDecision(String detail) {
        if (properties.getSubscription().isEntitlementFailOpen()) {
            log.warn("Entitlement check skipped (fail-open): {}", detail);
            return new Decision(true, "entitlement check skipped (fail-open)", null, null);
        }
        return new Decision(false, UNAVAILABLE, null, null);
    }
}
