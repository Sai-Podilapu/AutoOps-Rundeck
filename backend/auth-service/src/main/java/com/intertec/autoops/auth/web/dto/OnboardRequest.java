package com.intertec.autoops.auth.web.dto;

import com.intertec.autoops.auth.domain.UserRole;
import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

/**
 * tenantId is optional and, when present, must equal the calling admin's own
 * tenant — onboarding is always scoped to the caller's tenant (from their
 * access token), never to a client-chosen one.
 */
public record OnboardRequest(
        @NotBlank @Email String email,
        String fullName,
        @NotNull UserRole role,
        String tenantId) {
}
