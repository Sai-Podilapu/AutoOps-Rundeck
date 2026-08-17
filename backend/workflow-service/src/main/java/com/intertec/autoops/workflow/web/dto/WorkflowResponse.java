package com.intertec.autoops.workflow.web.dto;

import com.intertec.autoops.workflow.client.CoreClient;
import com.intertec.autoops.workflow.domain.Workflow;
import com.intertec.autoops.workflow.service.WorkflowComplexity;
import com.intertec.autoops.workflow.service.WorkflowComplexity.ComplexityRules;

import java.time.Instant;

/**
 * What the console sees. Run stats (successRate/lastRunAt/...) are aggregated
 * from core-service's runs and are null until the workflow has run at least
 * once; requiresApproval is COMPUTED from the tenant's complexity rules, never
 * stored.
 *
 * <p><b>Sealing.</b> A PROVIDER-authored workflow is the provider's product:
 * {@code definition} is withheld from every caller that is not itself a
 * PROVIDER, so the canvas never reaches a customer's browser. Everything
 * needed to operate it still ships — name, node count, enablement, run
 * history, whether it needs approval — because a sealed automation must remain
 * auditable. {@code nodeCount} and {@code requiresApproval} are derived from
 * the definition on the server BEFORE it is dropped, so sealing costs the
 * client no information it is entitled to.
 *
 * <p>The run engine reads the definition over {@code /internal}
 * ({@link WorkflowView}), which is service-to-service and never routed by the
 * gateway — that is what lets a sealed workflow still execute.
 */
public record WorkflowResponse(
        Long id,
        Long projectId,
        String name,
        String definition,
        int nodeCount,
        boolean enabled,
        boolean requiresApproval,
        String origin,
        boolean editable,
        Long runsTotal,
        Integer successRate,
        Instant lastRunAt,
        Long avgDurationMs,
        String createdBy,
        Instant createdAt,
        Instant updatedAt) {

    public static WorkflowResponse from(Workflow workflow, ComplexityRules rules,
                                        boolean callerIsProvider) {
        return from(workflow, null, rules, callerIsProvider);
    }

    public static WorkflowResponse from(Workflow workflow, CoreClient.RunStats stats,
                                        ComplexityRules rules, boolean callerIsProvider) {
        boolean sealed = workflow.isProviderAuthored() && !callerIsProvider;
        return new WorkflowResponse(workflow.getId(), workflow.getProjectId(),
                workflow.getName(),
                sealed ? null : workflow.getDefinition(),
                workflow.getNodeCount(),
                workflow.isEnabled(),
                // Computed from the real definition, then the definition is dropped.
                WorkflowComplexity.isComplex(workflow.getDefinition(), workflow.getNodeCount(),
                        rules),
                workflow.getOrigin().name(),
                !sealed,
                stats != null ? stats.total() : null,
                stats != null ? stats.successRate() : null,
                stats != null ? stats.lastRunAt() : null,
                stats != null ? stats.avgDurationMs() : null,
                workflow.getCreatedBy(), workflow.getCreatedAt(), workflow.getUpdatedAt());
    }
}
