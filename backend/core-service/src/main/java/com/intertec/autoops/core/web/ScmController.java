package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.ScmService;
import com.intertec.autoops.core.web.dto.ScmDto;
import jakarta.validation.Valid;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * Per-project git sync. Config writes are ADMIN-only (they carry the access
 * token); reads never return the token. Export/import are subscription-gated
 * mutations run with the caller's entitlements. Tenant always from the token
 * claim.
 */
@RestController
public class ScmController {

    private final ScmService scmService;
    private final com.intertec.autoops.core.service.AuditService auditService;

    public ScmController(ScmService scmService,
                         com.intertec.autoops.core.service.AuditService auditService) {
        this.scmService = scmService;
        this.auditService = auditService;
    }

    @GetMapping("/api/projects/{projectId}/scm")
    public ScmDto.ConfigResponse get(@PathVariable Long projectId,
                                     @AuthenticationPrincipal Jwt jwt) {
        return scmService.getConfig(tenant(jwt), projectId)
                .map(ScmDto.ConfigResponse::from)
                .orElseGet(ScmDto.ConfigResponse::unconfigured);
    }

    @PutMapping("/api/projects/{projectId}/scm")
    public ScmDto.ConfigResponse save(@PathVariable Long projectId,
                                      @Valid @RequestBody ScmDto.ConfigRequest request,
                                      @AuthenticationPrincipal Jwt jwt) {
        var config = scmService.saveConfig(tenant(jwt), jwt.getSubject(),
                jwt.getClaimAsString("role"), projectId, request.repoUrl(), request.branch(),
                request.basePath(), request.username(), request.token(), request.clearToken());
        auditService.record(CoreAuditEventType.SCM_CONFIGURED, tenant(jwt), jwt.getSubject(),
                projectId, "SCM", projectId, request.repoUrl(),
                "branch=" + config.getBranch()
                        + (request.clearToken() ? ", token cleared" : ""));
        return ScmDto.ConfigResponse.from(config);
    }

    @PostMapping("/api/projects/{projectId}/scm/export")
    public ScmDto.ExportResponse export(@PathVariable Long projectId,
                                        @AuthenticationPrincipal Jwt jwt) {
        var result = scmService.export(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), projectId);
        auditService.record(CoreAuditEventType.SCM_EXPORTED, tenant(jwt), jwt.getSubject(),
                projectId, "SCM", projectId, null,
                result.pushed()
                        ? "pushed " + (result.jobs() + result.workflows()) + " definitions"
                        : "no changes");
        return ScmDto.ExportResponse.from(result);
    }

    @PostMapping("/api/projects/{projectId}/scm/import")
    public ScmDto.ImportResponse importFrom(@PathVariable Long projectId,
                                            @RequestBody(required = false) ScmDto.ImportRequest request,
                                            @AuthenticationPrincipal Jwt jwt) {
        ScmService.ImportStrategy strategy = request != null
                ? request.toStrategy() : ScmService.ImportStrategy.OVERWRITE;
        var result = scmService.importFrom(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), projectId, strategy);
        auditService.record(CoreAuditEventType.SCM_IMPORTED, tenant(jwt), jwt.getSubject(),
                projectId, "SCM", projectId, null,
                "created=" + result.created() + ", updated=" + result.updated()
                        + ", skipped=" + result.skipped());
        return ScmDto.ImportResponse.from(result);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
