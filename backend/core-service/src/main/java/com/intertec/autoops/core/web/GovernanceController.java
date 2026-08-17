package com.intertec.autoops.core.web;

import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.GovernanceService;
import com.intertec.autoops.core.web.dto.GovernanceDto;
import jakarta.validation.Valid;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * Governance dashboard + policy modes. The summary is a read (never gated);
 * mode changes are ADMIN-only mutations gated on the GOVERNANCE plan
 * feature. Tenant always from the token claim.
 */
@RestController
public class GovernanceController {

    private final GovernanceService governanceService;
    private final com.intertec.autoops.core.service.AuditService auditService;

    public GovernanceController(GovernanceService governanceService,
                                com.intertec.autoops.core.service.AuditService auditService) {
        this.governanceService = governanceService;
        this.auditService = auditService;
    }

    @GetMapping("/api/governance/summary")
    public GovernanceDto.SummaryResponse summary(@AuthenticationPrincipal Jwt jwt) {
        return GovernanceDto.SummaryResponse.from(
                governanceService.summary(tenant(jwt), jwt.getTokenValue()));
    }

    @PutMapping("/api/governance/policies/{policy}")
    public GovernanceDto.PolicyResponse setMode(@PathVariable String policy,
                                                @Valid @RequestBody GovernanceDto.ModeRequest request,
                                                @AuthenticationPrincipal Jwt jwt) {
        var updated = governanceService.setMode(tenant(jwt),
                jwt.getSubject(), jwt.getClaimAsString("role"), jwt.getTokenValue(),
                policy, request.mode());
        auditService.record(com.intertec.autoops.core.domain.CoreAuditEventType
                        .GOVERNANCE_POLICY_UPDATED, tenant(jwt), jwt.getSubject(), null,
                "POLICY", null, policy, "mode=" + request.mode());
        return GovernanceDto.PolicyResponse.from(updated);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}