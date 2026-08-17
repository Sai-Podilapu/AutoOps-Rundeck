package com.intertec.autoops.plugin.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/** All plugin-service settings, kebab-case under {@code autoops.plugin.*}. */
@ConfigurationProperties("autoops.plugin")
public class PluginProperties {

    public static final String DEV_INTERNAL_TOKEN = "dev-internal-token";
    public static final String DEV_CREDENTIAL_KEY = "dev-plugin-cred-key";

    /** auth-service JWKS endpoint for local RS256 validation. */
    private String jwksUri = "http://localhost:8081/oauth2/jwks";

    /** Expected token issuer (must match auth-service's `iss` claim). */
    private String issuer = "autoops-auth-service";

    /** Shared secret this service requires on its OWN {@code /internal/**}. */
    private String internalToken = DEV_INTERNAL_TOKEN;

    /**
     * Secret backing AES-256-GCM encryption of every stored plugin credential.
     * Deliberately NOT core-service's CLOUD_CRED_KEY — one compromised key
     * must not open both vaults.
     */
    private String credentialKey = DEV_CREDENTIAL_KEY;

    /** Console origin used to build the deep link in a notification. */
    private String consoleBaseUrl = "http://localhost:5173";

    private final Delivery delivery = new Delivery();

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

    public String getCredentialKey() {
        return credentialKey;
    }

    public void setCredentialKey(String credentialKey) {
        this.credentialKey = credentialKey;
    }

    public String getConsoleBaseUrl() {
        return consoleBaseUrl;
    }

    public void setConsoleBaseUrl(String consoleBaseUrl) {
        this.consoleBaseUrl = consoleBaseUrl;
    }

    public Delivery getDelivery() {
        return delivery;
    }

    /** Outbound delivery tuning — timeouts, worker pool and the failure cap. */
    public static class Delivery {

        private Duration connectTimeout = Duration.ofSeconds(3);

        private Duration readTimeout = Duration.ofSeconds(10);

        /**
         * Consecutive failures after which an installation is parked. A
         * revoked Slack webhook returns 404 forever; retrying it on every
         * job run burns the pool and looks like abuse to the third party.
         */
        private int maxConsecutiveFailures = 20;

        private int workers = 8;

        private int queueCapacity = 500;

        /** How long a delivery attempt stays in the log before it is trimmed. */
        private Duration retention = Duration.ofDays(30);

        private Duration retentionInitialDelay = Duration.ofMinutes(5);

        private Duration retentionInterval = Duration.ofHours(12);

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

        public int getMaxConsecutiveFailures() {
            return maxConsecutiveFailures;
        }

        public void setMaxConsecutiveFailures(int maxConsecutiveFailures) {
            this.maxConsecutiveFailures = maxConsecutiveFailures;
        }

        public int getWorkers() {
            return workers;
        }

        public void setWorkers(int workers) {
            this.workers = workers;
        }

        public int getQueueCapacity() {
            return queueCapacity;
        }

        public void setQueueCapacity(int queueCapacity) {
            this.queueCapacity = queueCapacity;
        }

        public Duration getRetention() {
            return retention;
        }

        public void setRetention(Duration retention) {
            this.retention = retention;
        }

        public Duration getRetentionInitialDelay() {
            return retentionInitialDelay;
        }

        public void setRetentionInitialDelay(Duration retentionInitialDelay) {
            this.retentionInitialDelay = retentionInitialDelay;
        }

        public Duration getRetentionInterval() {
            return retentionInterval;
        }

        public void setRetentionInterval(Duration retentionInterval) {
            this.retentionInterval = retentionInterval;
        }
    }
}
