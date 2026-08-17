package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.ProjectService;
import com.intertec.autoops.core.web.dto.ProjectRequest;
import com.intertec.autoops.core.web.dto.ProjectResponse;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Tenant-scoped projects. The tenant is ALWAYS the caller's token claim —
 * never a header or body. Reads are open to any tenant member; mutations
 * pass the subscription gate inside the service layer.
 */
@RestController
@RequestMapping("/api/projects")
public class ProjectController {

    private final ProjectService projectService;
    private final com.intertec.autoops.core.service.AuditService auditService;

    public ProjectController(ProjectService projectService,
                             com.intertec.autoops.core.service.AuditService auditService) {
        this.projectService = projectService;
        this.auditService = auditService;
    }

    @GetMapping
    public List<ProjectResponse> list(@AuthenticationPrincipal Jwt jwt) {
        return projectService.list(tenant(jwt)).stream().map(ProjectResponse::from).toList();
    }

    @GetMapping("/{id}")
    public ProjectResponse get(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        return ProjectResponse.from(projectService.get(tenant(jwt), id));
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public ProjectResponse create(@Valid @RequestBody ProjectRequest request,
                                  @AuthenticationPrincipal Jwt jwt) {
        var project = projectService.create(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), request.name(), request.description());
        audit(CoreAuditEventType.PROJECT_CREATED, jwt, project.getId(), project.getName(), null);
        return ProjectResponse.from(project);
    }

    @PutMapping("/{id}")
    public ProjectResponse update(@PathVariable Long id,
                                  @Valid @RequestBody ProjectRequest request,
                                  @AuthenticationPrincipal Jwt jwt) {
        var project = projectService.update(tenant(jwt), jwt.getTokenValue(), id,
                request.name(), request.description());
        audit(CoreAuditEventType.PROJECT_UPDATED, jwt, project.getId(), project.getName(), null);
        return ProjectResponse.from(project);
    }

    @PostMapping("/{id}/archive")
    public ProjectResponse archive(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        var project = projectService.archive(tenant(jwt), jwt.getTokenValue(), id);
        audit(CoreAuditEventType.PROJECT_ARCHIVED, jwt, project.getId(), project.getName(), null);
        return ProjectResponse.from(project);
    }

    @PostMapping("/{id}/restore")
    public ProjectResponse restore(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        var project = projectService.restore(tenant(jwt), jwt.getTokenValue(), id);
        audit(CoreAuditEventType.PROJECT_RESTORED, jwt, project.getId(), project.getName(), null);
        return ProjectResponse.from(project);
    }

    private void audit(CoreAuditEventType type, Jwt jwt, Long projectId, String name,
                       String detail) {
        auditService.record(type, tenant(jwt), jwt.getSubject(), projectId, "PROJECT",
                projectId, name, detail);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
