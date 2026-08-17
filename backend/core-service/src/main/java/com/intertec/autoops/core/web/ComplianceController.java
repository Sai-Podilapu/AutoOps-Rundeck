package com.intertec.autoops.core.web;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.domain.ComplianceReport;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.ComplianceService;
import com.intertec.autoops.core.web.dto.ComplianceDto;
import jakarta.validation.Valid;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Locale;

/**
 * Compliance reporting. Generation is a subscription-gated mutation
 * (COMPLIANCE_REPORTS plan feature); listing, detail and download are
 * reads and never gated — a tenant can always see and export the
 * reports it already generated. Tenant always from the token claim.
 */
@RestController
public class ComplianceController {

    private final ComplianceService complianceService;
    private final ObjectMapper objectMapper;
    private final com.intertec.autoops.core.service.AuditService auditService;

    public ComplianceController(ComplianceService complianceService, ObjectMapper objectMapper,
                                com.intertec.autoops.core.service.AuditService auditService) {
        this.complianceService = complianceService;
        this.objectMapper = objectMapper;
        this.auditService = auditService;
    }

    @GetMapping("/api/projects/{projectId}/compliance/reports")
    public List<ComplianceDto.ReportSummary> list(@PathVariable Long projectId,
                                                  @AuthenticationPrincipal Jwt jwt) {
        return complianceService.list(tenant(jwt), projectId).stream()
                .map(ComplianceDto.ReportSummary::from)
                .toList();
    }

    @PostMapping("/api/projects/{projectId}/compliance/reports")
    @ResponseStatus(HttpStatus.CREATED)
    public ComplianceDto.ReportDetail generate(@PathVariable Long projectId,
                                               @Valid @RequestBody ComplianceDto.GenerateRequest request,
                                               @AuthenticationPrincipal Jwt jwt) {
        ComplianceReport report = complianceService.generate(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), projectId, request.framework());
        auditService.record(com.intertec.autoops.core.domain.CoreAuditEventType
                        .COMPLIANCE_REPORT_GENERATED, tenant(jwt), jwt.getSubject(), projectId,
                "REPORT", report.getId(), report.getFramework().name(),
                "status=" + report.getStatus());
        return ComplianceDto.ReportDetail.from(report, objectMapper);
    }

    @GetMapping("/api/compliance/reports/{reportId}")
    public ComplianceDto.ReportDetail get(@PathVariable Long reportId,
                                          @AuthenticationPrincipal Jwt jwt) {
        return ComplianceDto.ReportDetail.from(
                complianceService.get(tenant(jwt), reportId), objectMapper);
    }

    @GetMapping("/api/compliance/reports/{reportId}/download")
    public ResponseEntity<byte[]> download(@PathVariable Long reportId,
                                           @AuthenticationPrincipal Jwt jwt) {
        ComplianceReport report = complianceService.get(tenant(jwt), reportId);
        String filename = report.getFramework().name().toLowerCase(Locale.ROOT)
                .replace("_", "-") + "-report-" + report.getId() + ".pdf";
        return ResponseEntity.ok()
                .header(HttpHeaders.CONTENT_DISPOSITION,
                        "attachment; filename=\"" + filename + "\"")
                .contentType(MediaType.APPLICATION_PDF)
                .body(complianceService.renderPdf(report));
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}