package com.intertec.autoops.agent.web.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * {@code tools} is the agent's allow-list as JSON —
 * {@code [{"type":"JOB","id":7},{"type":"WORKFLOW","id":3,"mutating":false}]} —
 * validated against the agent's own project (jobs via core-service, workflows
 * via workflow-service). On update, a null field is left unchanged.
 *
 * <p>{@code mutating} on an entry is optional and defaults to TRUE when absent.
 * It is what lets the Python runtime keep a state-changing tool out of the phase
 * that is still gathering evidence, and it is declared by whoever authored the
 * agent because nothing else in the platform records whether a saved automation
 * changes anything.
 *
 * <p>{@code instructions} and {@code graphRef} are alternatives, not companions.
 * A JSON-authored agent carries its persona in {@code instructions}, which means
 * a copy of it lands in the customer's own database. A Python-authored one
 * carries only {@code graphRef} — a name in agent-runtime's registry — and its
 * persona, prompts and phase graph stay in the provider's image.
 */
public record AgentRequest(
        @NotBlank @Size(max = 128) String name,
        @Size(max = 512) String description,
        @Size(max = 128) String model,
        String instructions,
        @Size(max = 128) String graphRef,
        @Size(max = 32) String graphVersion,
        String tools) {
}
