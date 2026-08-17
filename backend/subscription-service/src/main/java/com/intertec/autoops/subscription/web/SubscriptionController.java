package com.intertec.autoops.subscription.web;

import com.intertec.autoops.subscription.domain.PlanCode;
import com.intertec.autoops.subscription.exception.SubscriptionException;
import com.intertec.autoops.subscription.service.SubscriptionService;
import com.intertec.autoops.subscription.web.dto.SubscribeRequest;
import com.intertec.autoops.subscription.web.dto.SubscriptionResponse;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * Tenant-scoped subscription management. The tenant is ALWAYS taken from the
 * caller's access token (`tenantId` claim) — never from a header or body, so
 * one workspace can never manage another's subscription.
 */
@RestController
@RequestMapping("/api/subscriptions")
public class SubscriptionController {

    private final SubscriptionService subscriptionService;

    public SubscriptionController(SubscriptionService subscriptionService) {
        this.subscriptionService = subscriptionService;
    }

    @GetMapping("/current")
    public ResponseEntity<?> current(@AuthenticationPrincipal Jwt jwt) {
        return subscriptionService.findCurrent(tenant(jwt))
                .<ResponseEntity<?>>map(s -> ResponseEntity.ok(SubscriptionResponse.from(s)))
                .orElseGet(() -> ResponseEntity.ok(Map.of("status", "NONE")));
    }

    /** Workspace admins (and platform providers) manage the subscription. */
    @PostMapping("/subscribe")
    @PreAuthorize("hasAnyRole('ADMIN','PROVIDER')")
    public SubscriptionResponse subscribe(@Valid @RequestBody SubscribeRequest request,
                                          @AuthenticationPrincipal Jwt jwt) {
        PlanCode planCode = PlanCode.fromCode(request.planCode());
        if (planCode == null) {
            throw SubscriptionException.badRequest("unknown_plan",
                    "Unknown plan: " + request.planCode());
        }
        return SubscriptionResponse.from(
                subscriptionService.subscribe(tenant(jwt), planCode, jwt.getSubject()));
    }

    @PostMapping("/cancel")
    @PreAuthorize("hasAnyRole('ADMIN','PROVIDER')")
    public SubscriptionResponse cancel(@AuthenticationPrincipal Jwt jwt) {
        return SubscriptionResponse.from(subscriptionService.cancel(tenant(jwt), jwt.getSubject()));
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw SubscriptionException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
