package com.intertec.autoops.auth.client;

import com.intertec.autoops.auth.config.AuthProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpHeaders;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.util.Map;

/**
 * Entitlement checks against subscription-service (bounded 2s/3s timeouts).
 *
 * <p><strong>FAIL-CLOSED</strong> by default when the service is unreachable;
 * set ENTITLEMENT_FAIL_OPEN=true to allow access during subscription-service
 * outages instead.
 */
@Component
public class SubscriptionServiceClient {

    private static final Logger log = LoggerFactory.getLogger(SubscriptionServiceClient.class);

    private final RestClient subscriptionRestClient;
    private final AuthProperties properties;

    public SubscriptionServiceClient(@Qualifier("subscriptionRestClient") RestClient subscriptionRestClient,
                                     AuthProperties properties) {
        this.subscriptionRestClient = subscriptionRestClient;
        this.properties = properties;
    }

    public record EntitlementResult(boolean entitled, String reason) {
    }

    public EntitlementResult checkEntitlement(String accessToken, String tenantId, String feature) {
        if (feature == null || feature.isBlank()) {
            return new EntitlementResult(true, ""); // nothing to check
        }
        try {
            // Canonical contract: POST /api/entitlements/check with the END
            // USER's bearer — subscription-service reads the tenant from the
            // token's own claim.
            Map<String, Object> response = subscriptionRestClient.post()
                    .uri("/api/entitlements/check")
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                    .header("X-Tenant-ID", tenantId)
                    .body(Map.of("feature", feature))
                    .retrieve()
                    .body(new ParameterizedTypeReference<Map<String, Object>>() {
                    });
            if (response == null) {
                return failResult("Empty entitlement response");
            }
            boolean entitled = Boolean.TRUE.equals(response.get("entitled"));
            String reason = response.get("reason") != null ? response.get("reason").toString() : "";
            return new EntitlementResult(entitled, reason);
        } catch (Exception ex) {
            log.warn("Entitlement check failed for feature '{}': {}", feature, ex.getMessage());
            return failResult("Entitlement service unavailable");
        }
    }

    private EntitlementResult failResult(String reason) {
        if (properties.getSubscription().isEntitlementFailOpen()) {
            return new EntitlementResult(true, "entitlement check skipped (fail-open): " + reason);
        }
        return new EntitlementResult(false, reason);
    }
}
