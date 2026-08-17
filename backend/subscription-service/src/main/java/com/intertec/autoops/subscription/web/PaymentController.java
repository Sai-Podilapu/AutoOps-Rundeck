package com.intertec.autoops.subscription.web;

import com.intertec.autoops.subscription.exception.SubscriptionException;
import com.intertec.autoops.subscription.service.PaymentService;
import com.intertec.autoops.subscription.web.dto.PaymentResponse;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Payment history + recovery. Tenant ALWAYS from the caller's token claim.
 * Card/checkout collection is deliberately absent — that arrives with the
 * real provider (Stripe Checkout/Elements) behind the same PaymentProvider
 * seam; these endpoints will not change.
 */
@RestController
@RequestMapping("/api/payments")
public class PaymentController {

    private final PaymentService paymentService;

    public PaymentController(PaymentService paymentService) {
        this.paymentService = paymentService;
    }

    @GetMapping
    public List<PaymentResponse> history(@AuthenticationPrincipal Jwt jwt) {
        return paymentService.history(tenant(jwt)).stream().map(PaymentResponse::from).toList();
    }

    /** Retries the latest failed charge; success lifts PAST_DUE back to ACTIVE. */
    @PostMapping("/retry")
    @PreAuthorize("hasAnyRole('ADMIN','PROVIDER')")
    public PaymentResponse retry(@AuthenticationPrincipal Jwt jwt) {
        return PaymentResponse.from(paymentService.retryLatestFailed(tenant(jwt), jwt.getSubject()));
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw SubscriptionException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
