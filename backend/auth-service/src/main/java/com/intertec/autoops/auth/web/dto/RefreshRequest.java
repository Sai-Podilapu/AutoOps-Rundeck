package com.intertec.autoops.auth.web.dto;

import jakarta.validation.constraints.NotBlank;

/** Body for /refresh and /logout — both operate on the opaque refresh token. */
public record RefreshRequest(
        @NotBlank String refreshToken) {
}
