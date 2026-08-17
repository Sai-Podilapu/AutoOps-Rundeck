package com.intertec.autoops.auth.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Lazy;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtDecoders;
import org.springframework.web.client.RestClient;

/**
 * Keycloak OIDC integration beans. Both beans are lazy so the service can boot
 * without a reachable Keycloak (SSO endpoints will fail at call time instead).
 */
@Configuration
public class KeycloakConfig {

    /** Validates Keycloak-issued tokens (ID tokens from the code exchange). */
    @Bean("keycloakJwtDecoder")
    @Lazy
    public JwtDecoder keycloakJwtDecoder(AuthProperties properties) {
        return JwtDecoders.fromIssuerLocation(properties.getKeycloak().getIssuerUri());
    }

    /** RestClient for the Keycloak token endpoint, with bounded timeouts. */
    @Bean("keycloakRestClient")
    @Lazy
    public RestClient keycloakRestClient(AuthProperties properties) {
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(2_000);
        requestFactory.setReadTimeout(5_000);
        return RestClient.builder()
                .baseUrl(properties.getKeycloak().getIssuerUri())
                .requestFactory(requestFactory)
                .build();
    }
}
