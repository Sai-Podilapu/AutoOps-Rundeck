package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.ApprovalService;
import com.intertec.autoops.core.service.ApprovalSettingsService;
import com.intertec.autoops.core.web.dto.ApprovalResponse;
import com.intertec.autoops.core.web.dto.ApprovalSettingsDto;
import jakarta.validation.Valid;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Approval requests (requires_approval jobs + complex workflows) and the
 * per-tenant complexity-threshold settings. Listing/reading is open to the
 * tenant (reads are never gated); approve/reject and settings changes
 * require the ADMIN role claim — approving starts the run with the admin's
 * token. Tenant always from the token claim.
 */
@RestController
public class ApprovalController {

    private final ApprovalService approvalService;
    private final ApprovalSettingsService settingsService;
    private final com.intertec.autoops.core.service.AuditService auditService;

    public ApprovalController(ApprovalService approvalService,
                              ApprovalSettingsService settingsService,
                              com.intertec.autoops.core.service.AuditService auditService) {
        this.approvalService = approvalService;
        this.settingsService = settingsService;
        this.auditService = auditService;
    }

    @GetMapping("/api/approvals/settings")
    public ApprovalSettingsDto.Response settings(@AuthenticationPrincipal Jwt jwt) {
        return ApprovalSettingsDto.Response.from(settingsService.get(tenant(jwt)));
    }

    @PutMapping("/api/approvals/settings")
    public ApprovalSettingsDto.Response updateSettings(
            @Valid @RequestBody ApprovalSettingsDto.UpdateRequest request,
            @AuthenticationPrincipal Jwt jwt) {
        var updated = settingsService.update(tenant(jwt),
                jwt.getSubject(), jwt.getClaimAsString("role"), request.complexNodeThreshold(),
                request.riskyTypes());
        auditService.record(CoreAuditEventType.APPROVAL_SETTINGS_UPDATED, tenant(jwt),
                jwt.getSubject(), null, "SETTINGS", null, "workflow approval rule",
                "threshold=" + (request.complexNodeThreshold() != null
                        ? request.complexNodeThreshold() : "unchanged")
                        + ", riskyTypes=" + (request.riskyTypes() != null
                        ? String.join(",", request.riskyTypes()) : "unchanged"));
        return ApprovalSettingsDto.Response.from(updated);
    }

    @GetMapping("/api/approvals")
    public List<ApprovalResponse> list(@RequestParam(required = false) Long projectId,
                                       @AuthenticationPrincipal Jwt jwt) {
        return approvalService.list(tenant(jwt), projectId)
                .stream().map(ApprovalResponse::from).toList();
    }

    @PostMapping("/api/approvals/{id}/approve")
    public ApprovalResponse approve(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        var approval = approvalService.approve(tenant(jwt), jwt.getSubject(),
                jwt.getClaimAsString("role"), jwt.getTokenValue(), id);
        auditService.record(CoreAuditEventType.APPROVAL_APPROVED, tenant(jwt), jwt.getSubject(),
                approval.getProjectId(), approval.getTargetType().name(),
                approval.getTargetId(), approval.getTargetName(),
                "requested by " + approval.getRequestedBy());
        return ApprovalResponse.from(approval);
    }

    @PostMapping("/api/approvals/{id}/reject")
    public ApprovalResponse reject(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        var approval = approvalService.reject(tenant(jwt), jwt.getSubject(),
                jwt.getClaimAsString("role"), id);
        auditService.record(CoreAuditEventType.APPROVAL_REJECTED, tenant(jwt), jwt.getSubject(),
                approval.getProjectId(), approval.getTargetType().name(),
                approval.getTargetId(), approval.getTargetName(),
                "requested by " + approval.getRequestedBy());
        return ApprovalResponse.from(approval);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}