package com.intertec.autoops.auth.web.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;

import java.util.List;

/**
 * A tenant's own IdP registration. Endpoint URLs are optional — blank ones
 * are filled from the issuer's OIDC discovery document. clientSecret may be
 * omitted on updates to keep the stored one.
 */
public record IdpConfigRequest(
        @NotBlank String issuer,
        @NotBlank String clientId,
        String clientSecret,
        @NotEmpty List<String> emailDomains,
        boolean enforceSso,
        String authorizeUrl,
        String tokenUrl,
        String userinfoUrl) {
}
