package com.intertec.autoops.agent.web.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * {@code tools} is the agent's allow-list as JSON —
 * {@code [{"type":"JOB","id":7},{"type":"WORKFLOW","id":3}]} — validated
 * against the agent's own project (jobs via core-service, workflows via
 * workflow-service). On update, a null field is left unchanged.
 */
public record AgentRequest(
        @NotBlank @Size(max = 128) String name,
        @Size(max = 512) String description,
        @Size(max = 128) String model,
        String instructions,
        String tools) {
}
