package com.intertec.autoops.auth.web.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;

public record OtpGenerateRequest(
        @NotBlank @Email String email) {
}
