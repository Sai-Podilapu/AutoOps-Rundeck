package com.intertec.autoops.workflow.web;

import com.intertec.autoops.workflow.client.CoreClient;
import com.intertec.autoops.workflow.domain.Workflow;
import com.intertec.autoops.workflow.exception.WorkflowException;
import com.intertec.autoops.workflow.service.WorkflowService;
import com.intertec.autoops.workflow.web.dto.WorkflowRequest;
import com.intertec.autoops.workflow.web.dto.WorkflowResponse;
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
 * Automation workflows. Same paths, same payloads and same error codes the
 * console already used when this lived in core-service — the gateway simply
 * points them here instead.
 *
 * <p>{@code POST /api/workflows/{id}/run} is NOT here: triggering is
 * execution, and the run engine, approvals and run history all stayed in
 * core-service. The gateway routes that one path there.
 */
@RestController
public class WorkflowController {

    private final WorkflowService workflowService;
    private final CoreClient coreClient;

    public WorkflowController(WorkflowService workflowService, CoreClient coreClient) {
        this.workflowService = workflowService;
        this.coreClient = coreClient;
    }

    @GetMapping("/api/projects/{projectId}/workflows")
    public List<WorkflowResponse> list(@PathVariable Long projectId,
                                       @AuthenticationPrincipal Jwt jwt) {
        String tenantId = tenant(jwt);
        boolean asProvider = isProvider(jwt);
        List<Workflow> workflows = workflowService.list(tenantId, projectId);
        // Two batch calls for the whole list — no per-row round trips.
        var stats = coreClient.statsForProject(tenantId, projectId);
        var rules = coreClient.complexityRules(tenantId);
        return workflows.stream()
                .map(w -> WorkflowResponse.from(w, stats.get(w.getId()), rules, asProvider))
                .toList();
    }

    /**
     * Authoring a workflow is a PROVIDER capability. A tenant builds jobs and
     * scripts; the workflows it runs are rolled out from the platform catalog
     * (POST /api/provider/rollout in core-service), which reaches this service
     * over /internal. This endpoint stays only to answer honestly.
     */
    @PostMapping("/api/projects/{projectId}/workflows")
    @ResponseStatus(HttpStatus.CREATED)
    public WorkflowResponse create(@PathVariable Long projectId,
                                   @Valid @RequestBody WorkflowRequest request,
                                   @AuthenticationPrincipal Jwt jwt) {
        throw WorkflowException.forbidden("provider_authored_only",
                "Workflows are designed by your provider and rolled out to your workspace. "
                        + "Build a job or a script instead.");
    }

    @GetMapping("/api/workflows/{id}")
    public WorkflowResponse get(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        String tenantId = tenant(jwt);
        Workflow workflow = workflowService.get(tenantId, id);
        return WorkflowResponse.from(workflow,
                coreClient.statsForWorkflow(tenantId, workflow.getProjectId(), id),
                coreClient.complexityRules(tenantId), isProvider(jwt));
    }

    @PutMapping("/api/workflows/{id}")
    public WorkflowResponse update(@PathVariable Long id,
                                   @Valid @RequestBody WorkflowRequest request,
                                   @AuthenticationPrincipal Jwt jwt) {
        Workflow workflow = workflowService.update(tenant(jwt), jwt.getTokenValue(), id,
                request.name(), request.definition(), isProvider(jwt));
        audit("WORKFLOW_UPDATED", jwt, workflow);
        return WorkflowResponse.from(workflow, coreClient.complexityRules(tenant(jwt)),
                isProvider(jwt));
    }

    // Enable/disable stay open to the tenant: a rolled-out workflow runs in
    // THEIR workspace, so pausing it is theirs to decide.
    @PostMapping("/api/workflows/{id}/enable")
    public WorkflowResponse enable(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        Workflow workflow = workflowService.setEnabled(tenant(jwt), jwt.getTokenValue(), id, true);
        audit("WORKFLOW_ENABLED", jwt, workflow);
        return WorkflowResponse.from(workflow, coreClient.complexityRules(tenant(jwt)),
                isProvider(jwt));
    }

    @PostMapping("/api/workflows/{id}/disable")
    public WorkflowResponse disable(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        Workflow workflow = workflowService.setEnabled(tenant(jwt), jwt.getTokenValue(), id, false);
        audit("WORKFLOW_DISABLED", jwt, workflow);
        return WorkflowResponse.from(workflow, coreClient.complexityRules(tenant(jwt)),
                isProvider(jwt));
    }

    @DeleteMapping("/api/workflows/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        Workflow workflow = workflowService.get(tenant(jwt), id); // snapshot before it's gone
        workflowService.delete(tenant(jwt), jwt.getTokenValue(), id, isProvider(jwt));
        audit("WORKFLOW_DELETED", jwt, workflow);
    }

    private static boolean isProvider(Jwt jwt) {
        return "PROVIDER".equals(jwt.getClaimAsString("role"));
    }

    private void audit(String eventType, Jwt jwt, Workflow workflow) {
        coreClient.audit(eventType, tenant(jwt), jwt.getSubject(), workflow.getProjectId(),
                workflow.getId(), workflow.getName());
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw WorkflowException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
