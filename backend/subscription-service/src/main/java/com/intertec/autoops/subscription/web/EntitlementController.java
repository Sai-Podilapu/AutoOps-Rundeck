package com.intertec.autoops.subscription.web;

import com.intertec.autoops.subscription.domain.LimitType;
import com.intertec.autoops.subscription.exception.SubscriptionException;
import com.intertec.autoops.subscription.service.EntitlementService;
import com.intertec.autoops.subscription.web.dto.EntitlementCheckRequest;
import com.intertec.autoops.subscription.web.dto.EntitlementCheckResponse;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Called by auth-service (/api/auth/authorize), the gateway, and resource
 * services (project/workflow creation) with the END USER's bearer token — the
 * tenant comes from that token's claim, so a caller can only ever ask about
 * its own tenant.
 *
 * <p>One endpoint, two gates: the feature gate (cached), then the quota gate
 * (the caller supplies its own current count). A denial from the first gate
 * short-circuits the second.
 */
@RestController
@RequestMapping("/api/entitlements")
public class EntitlementController {

    private final EntitlementService entitlementService;

    public EntitlementController(EntitlementService entitlementService) {
        this.entitlementService = entitlementService;
    }

    @PostMapping("/check")
    public EntitlementCheckResponse check(@RequestBody(required = false) EntitlementCheckRequest request,
                                          @AuthenticationPrincipal Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        String feature = request != null ? request.feature() : null;
        EntitlementCheckRequest.QuotaCheck quota = request != null ? request.quota() : null;

        if (quota == null) {
            EntitlementService.Decision decision = entitlementService.check(tenantId, feature);
            return new EntitlementCheckResponse(decision.entitled(), decision.reason());
        }

        LimitType limit = LimitType.fromCode(quota.limit());
        if (limit == null) {
            throw SubscriptionException.badRequest("unknown_limit",
                    "Unknown quota limit: " + quota.limit());
        }
        if (quota.current() == null || quota.current() < 0) {
            throw SubscriptionException.badRequest("invalid_quota",
                    "quota.current must be a non-negative count");
        }
        if (feature != null && !feature.isBlank()) {
            EntitlementService.Decision gate = entitlementService.check(tenantId, feature);
            if (!gate.entitled()) {
                return new EntitlementCheckResponse(false, gate.reason());
            }
        }
        EntitlementService.QuotaDecision decision =
                entitlementService.quota(tenantId, limit, quota.current());
        return new EntitlementCheckResponse(decision.entitled(), decision.reason(),
                decision.max(), decision.remaining());
    }
}
