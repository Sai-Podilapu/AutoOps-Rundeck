package com.intertec.autoops.subscription.web;

import com.intertec.autoops.subscription.exception.SubscriptionException;
import com.intertec.autoops.subscription.service.EntitlementService;
import com.intertec.autoops.subscription.web.dto.EntitlementCheckResponse;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * Service-to-service entitlement check for callers that legitimately have NO
 * user token — today: core-service's cron scheduler deciding whether a
 * scheduled run may fire. Takes the tenant EXPLICITLY (unlike the public
 * endpoint, which reads it from the caller's JWT), so it is guarded by the
 * shared internal token ({@link
 * com.intertec.autoops.subscription.security.InternalTokenFilter}) and never
 * routed through the gateway.
 */
@RestController
public class InternalEntitlementController {

    private final EntitlementService entitlementService;

    public InternalEntitlementController(EntitlementService entitlementService) {
        this.entitlementService = entitlementService;
    }

    public record InternalCheckRequest(String tenantId, String feature) {
    }

    @PostMapping("/internal/entitlements/check")
    public EntitlementCheckResponse check(@RequestBody InternalCheckRequest request) {
        if (request == null || request.tenantId() == null || request.tenantId().isBlank()) {
            throw SubscriptionException.badRequest("missing_tenant", "tenantId is required");
        }
        EntitlementService.Decision decision =
                entitlementService.check(request.tenantId(), request.feature());
        return new EntitlementCheckResponse(decision.entitled(), decision.reason());
    }
}
