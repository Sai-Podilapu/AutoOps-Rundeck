package com.intertec.autoops.auth.web.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/** Completes the forgot-password flow: emailed code + the new password. */
public record ResetPasswordRequest(
        @NotBlank @Email String email,
        @NotBlank String otp,
        @NotBlank @Size(min = 8, message = "Password must be at least 8 characters")
        String newPassword,
        String deviceId) {
}
