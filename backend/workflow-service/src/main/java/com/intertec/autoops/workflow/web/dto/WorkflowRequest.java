package com.intertec.autoops.workflow.web.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * definition is the canvas JSON ({@code {"nodes":[...],"edges":[...]}});
 * its node count is parsed server-side and gated by the plan's MAX_NODES.
 */
public record WorkflowRequest(
        @NotBlank @Size(max = 128) String name,
        String definition) {
}
