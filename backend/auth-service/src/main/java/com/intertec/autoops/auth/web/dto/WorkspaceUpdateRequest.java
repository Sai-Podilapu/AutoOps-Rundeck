package com.intertec.autoops.auth.web.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/** Admin rename of the caller's own workspace (the tenant slug never changes). */
public record WorkspaceUpdateRequest(
        @NotBlank @Size(max = 128) String name) {
}
