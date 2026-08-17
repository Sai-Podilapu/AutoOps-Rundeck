package com.intertec.autoops.workflow.web.dto;

import com.intertec.autoops.workflow.domain.Workflow;

/**
 * The internal projection other services see. Deliberately smaller than
 * {@link WorkflowResponse}: no run stats and no requiresApproval, because
 * core-service — the only caller that needs those — already owns the runs and
 * the approval rules and would be asking itself through two hops.
 */
public record WorkflowView(
        Long id,
        String tenantId,
        Long projectId,
        String name,
        String definition,
        int nodeCount,
        boolean enabled) {

    public static WorkflowView from(Workflow workflow) {
        return new WorkflowView(workflow.getId(), workflow.getTenantId(), workflow.getProjectId(),
                workflow.getName(), workflow.getDefinition(), workflow.getNodeCount(),
                workflow.isEnabled());
    }
}
