package com.intertec.autoops.auth.web.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Self-service registration. Creates a NEW workspace tenant with this account
 * as its ADMIN; workspaceName (optional) seeds the tenant id slug.
 */
public record RegisterRequest(
        @NotBlank @Email String email,
        @NotBlank @Size(min = 8, message = "Password must be at least 8 characters") String password,
        String fullName,
        String workspaceName) {
}
