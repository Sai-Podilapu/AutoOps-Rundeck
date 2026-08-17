package com.intertec.autoops.core.web.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/** Create/update payload; description is optional. */
public record ProjectRequest(
        @NotBlank @Size(max = 128) String name,
        @Size(max = 255) String description) {
}
