package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.domain.RunTargetType;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.JobService;
import com.intertec.autoops.core.service.RunService;
import com.intertec.autoops.core.web.dto.JobRequest;
import com.intertec.autoops.core.web.dto.JobResponse;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Job definitions. Nested under the owning project for list/create; flat by
 * id for everything else. Tenant always from the token claim.
 */
@RestController
public class JobController {

    private final JobService jobService;
    private final RunService runService;
    private final com.intertec.autoops.core.service.AuditService auditService;

    public JobController(JobService jobService, RunService runService,
                         com.intertec.autoops.core.service.AuditService auditService) {
        this.jobService = jobService;
        this.runService = runService;
        this.auditService = auditService;
    }

    @GetMapping("/api/projects/{projectId}/jobs")
    public List<JobResponse> list(@PathVariable Long projectId,
                                  @AuthenticationPrincipal Jwt jwt) {
        // One batch stats query for the whole list — no per-row lookups.
        var stats = runService.statsForProject(tenant(jwt), RunTargetType.JOB, projectId);
        return jobService.list(tenant(jwt), projectId).stream()
                .map(j -> JobResponse.from(j, stats.get(j.getId()))).toList();
    }

    @PostMapping("/api/projects/{projectId}/jobs")
    @ResponseStatus(HttpStatus.CREATED)
    public JobResponse create(@PathVariable Long projectId,
                              @Valid @RequestBody JobRequest request,
                              @AuthenticationPrincipal Jwt jwt) {
        var job = jobService.create(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), projectId, request.name(), request.group(),
                request.description(), request.definition(), request.schedule(),
                request.scheduleTimezone(), request.requiresApproval());
        audit(CoreAuditEventType.JOB_CREATED, jwt, job.getProject().getId(), job.getId(),
                job.getName(), null);
        return JobResponse.from(job);
    }

    @GetMapping("/api/jobs/{id}")
    public JobResponse get(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        return JobResponse.from(jobService.get(tenant(jwt), id),
                runService.statsForTarget(tenant(jwt), RunTargetType.JOB, id).orElse(null));
    }

    @PutMapping("/api/jobs/{id}")
    public JobResponse update(@PathVariable Long id,
                              @Valid @RequestBody JobRequest request,
                              @AuthenticationPrincipal Jwt jwt) {
        var job = jobService.update(tenant(jwt), jwt.getTokenValue(), id,
                request.name(), request.group(), request.description(),
                request.definition(), request.schedule(), request.scheduleTimezone(),
                request.requiresApproval());
        audit(CoreAuditEventType.JOB_UPDATED, jwt, job.getProject().getId(), job.getId(),
                job.getName(), null);
        return JobResponse.from(job);
    }

    @PostMapping("/api/jobs/{id}/enable")
    public JobResponse enable(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        return JobResponse.from(jobService.setEnabled(tenant(jwt), jwt.getTokenValue(), id, true));
    }

    @PostMapping("/api/jobs/{id}/disable")
    public JobResponse disable(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        return JobResponse.from(jobService.setEnabled(tenant(jwt), jwt.getTokenValue(), id, false));
    }

    @DeleteMapping("/api/jobs/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        var job = jobService.get(tenant(jwt), id); // snapshot before it's gone
        jobService.delete(tenant(jwt), jwt.getTokenValue(), id);
        audit(CoreAuditEventType.JOB_DELETED, jwt, job.getProject().getId(), id,
                job.getName(), null);
    }

    private void audit(CoreAuditEventType type, Jwt jwt, Long projectId, Long jobId,
                       String name, String detail) {
        auditService.record(type, tenant(jwt), jwt.getSubject(), projectId, "JOB",
                jobId, name, detail);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
