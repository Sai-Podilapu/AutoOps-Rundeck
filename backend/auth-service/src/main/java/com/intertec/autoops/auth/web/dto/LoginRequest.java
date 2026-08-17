package com.intertec.autoops.auth.web.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;

/** Password login. Tenant is resolved from TenantContext (X-Tenant-ID / default). */
public record LoginRequest(
        @NotBlank @Email String email,
        @NotBlank String password,
        String deviceId) {
}
