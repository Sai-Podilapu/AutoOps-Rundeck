package com.intertec.autoops.auth.web.dto;

import com.intertec.autoops.auth.domain.TenantIdpConfig;

import java.util.List;

/** The client secret is never returned — only whether one is stored. */
public record IdpConfigResponse(
        String issuer,
        String authorizeUrl,
        String tokenUrl,
        String userinfoUrl,
        String clientId,
        boolean secretConfigured,
        List<String> emailDomains,
        boolean enforceSso,
        boolean enabled) {

    public static IdpConfigResponse from(TenantIdpConfig config) {
        return new IdpConfigResponse(config.getIssuer(), config.getAuthorizeUrl(),
                config.getTokenUrl(), config.getUserinfoUrl(), config.getClientId(),
                config.getClientSecret() != null && !config.getClientSecret().isBlank(),
                List.copyOf(config.getEmailDomains()), config.isEnforceSso(),
                config.isEnabled());
    }
}
