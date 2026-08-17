package com.intertec.autoops.auth.web.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;

public record OtpVerifyRequest(
        @NotBlank @Email String email,
        @NotBlank String otp,
        String deviceId) {
}
