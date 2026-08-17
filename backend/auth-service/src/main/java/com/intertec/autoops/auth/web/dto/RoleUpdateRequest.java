package com.intertec.autoops.auth.web.dto;

import com.intertec.autoops.auth.domain.UserRole;
import jakarta.validation.constraints.NotNull;

/** Admin changes a member's role within the caller's own tenant. */
public record RoleUpdateRequest(@NotNull UserRole role) {
}
