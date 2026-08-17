package com.intertec.autoops.auth.web.dto;

import jakarta.validation.constraints.NotBlank;

/** feature is optional — when present, entitlement is checked with subscription-service. */
public record AuthorizeRequest(
        @NotBlank String token,
        String feature) {
}
