package com.intertec.autoops.workflow.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/** All workflow-service settings, kebab-case under {@code autoops.workflow.*}. */
@ConfigurationProperties("autoops.workflow")
public class WorkflowProperties {

    public static final String DEV_INTERNAL_TOKEN = "dev-internal-token";

    /** auth-service JWKS endpoint for local RS256 validation. */
    private String jwksUri = "http://localhost:8081/oauth2/jwks";

    /** Expected token issuer (must match auth-service's `iss` claim). */
    private String issuer = "autoops-auth-service";

    /** Shared secret this service requires on its OWN {@code /internal/**}. */
    private String internalToken = DEV_INTERNAL_TOKEN;

    private final Subscription subscription = new Subscription();

    private final Peer core = new Peer("http://localhost:8083", Duration.ofSeconds(5));

    private final Peer agent = new Peer("http://localhost:8087", Duration.ofSeconds(3));

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

    public String getInternalToken() {
        return internalToken;
    }

    public void setInternalToken(String internalToken) {
        this.internalToken = internalToken;
    }

    public Subscription getSubscription() {
        return subscription;
    }

    public Peer getCore() {
        return core;
    }

    public Peer getAgent() {
        return agent;
    }

    /** Another AutoOps service reached over its shared-secret internal API. */
    public static class Peer {

        private String baseUrl;

        private Duration connectTimeout = Duration.ofSeconds(2);

        private Duration readTimeout;

        private String internalToken = DEV_INTERNAL_TOKEN;

        public Peer(String baseUrl, Duration readTimeout) {
            this.baseUrl = baseUrl;
            this.readTimeout = readTimeout;
        }

        public String getBaseUrl() {
            return baseUrl;
        }

        public void setBaseUrl(String baseUrl) {
            this.baseUrl = baseUrl;
        }

        public Duration getConnectTimeout() {
            return connectTimeout;
        }

        public void setConnectTimeout(Duration connectTimeout) {
            this.connectTimeout = connectTimeout;
        }

        public Duration getReadTimeout() {
            return readTimeout;
        }

        public void setReadTimeout(Duration readTimeout) {
            this.readTimeout = readTimeout;
        }

        public String getInternalToken() {
            return internalToken;
        }

        public void setInternalToken(String internalToken) {
            this.internalToken = internalToken;
        }
    }

    /** Entitlement/quota decisions come from subscription-service. */
    public static class Subscription {

        private String baseUrl = "http://localhost:8082";

        private Duration connectTimeout = Duration.ofSeconds(2);

        private Duration readTimeout = Duration.ofSeconds(3);

        /**
         * FAIL-CLOSED by default: when subscription-service is unreachable,
         * mutations are denied. Set true to allow them during outages instead.
         */
        private boolean entitlementFailOpen = false;

        public String getBaseUrl() {
            return baseUrl;
        }

        public void setBaseUrl(String baseUrl) {
            this.baseUrl = baseUrl;
        }

        public Duration getConnectTimeout() {
            return connectTimeout;
        }

        public void setConnectTimeout(Duration connectTimeout) {
            this.connectTimeout = connectTimeout;
        }

        public Duration getReadTimeout() {
            return readTimeout;
        }

        public void setReadTimeout(Duration readTimeout) {
            this.readTimeout = readTimeout;
        }

        public boolean isEntitlementFailOpen() {
            return entitlementFailOpen;
        }

        public void setEntitlementFailOpen(boolean entitlementFailOpen) {
            this.entitlementFailOpen = entitlementFailOpen;
        }
    }
}
