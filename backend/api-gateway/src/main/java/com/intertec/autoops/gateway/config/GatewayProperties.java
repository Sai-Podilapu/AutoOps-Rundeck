package com.intertec.autoops.gateway.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.List;

/** All gateway settings, kebab-case under {@code autoops.gateway.*}. */
@ConfigurationProperties("autoops.gateway")
public class GatewayProperties {

    /** auth-service JWKS endpoint for local RS256 validation. */
    private String jwksUri = "http://localhost:8081/oauth2/jwks";

    /** Expected token issuer (must match auth-service's {@code iss} claim). */
    private String issuer = "autoops-auth-service";

    /** Browser origins allowed to call the platform through the gateway. */
    private List<String> corsAllowedOrigins =
            List.of("http://localhost:5173", "http://localhost:3000");

    public String getJwksUri() {
        return jwksUri;
    }

    public void setJwksUri(String jwksUri) {
        this.jwksUri = jwksUri;
    }

    public String getIssuer() {
        return issuer;
    }

    public void setIssuer(String issuer) {
        this.issuer = issuer;
    }

    public List<String> getCorsAllowedOrigins() {
        return corsAllowedOrigins;
    }

    public void setCorsAllowedOrigins(List<String> corsAllowedOrigins) {
        this.corsAllowedOrigins = corsAllowedOrigins;
    }
}