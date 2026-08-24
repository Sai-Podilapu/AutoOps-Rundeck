package com.intertec.autoops.rundeck.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/** All rundeck-service settings, kebab-case under {@code autoops.rundeck.*}. */
@ConfigurationProperties("autoops.rundeck")
public class RundeckProperties {

    public static final String DEV_INTERNAL_TOKEN = "dev-internal-token";

    public static final String DEV_CREDENTIAL_KEY = "dev-rundeck-cred-key";

    /** auth-service JWKS endpoint for local RS256 validation. */
    private String jwksUri = "http://localhost:8081/oauth2/jwks";

    /** Expected token issuer (must match auth-service's `iss` claim). */
    private String issuer = "autoops-auth-service";

    /** Shared secret this service requires on its OWN {@code /internal/**}. */
    private String internalToken = DEV_INTERNAL_TOKEN;

    /** AES-256-GCM key for stored Rundeck API tokens. */
    private String credentialKey = DEV_CREDENTIAL_KEY;

    private final Subscription subscription = new Subscription();

    private final Peer core = new Peer("http://localhost:8083", Duration.ofSeconds(5));

    private final Upstream upstream = new Upstream();

    private final Platform platform = new Platform();

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

    public Subscription getSubscription() {
        return subscription;
    }

    public Peer getCore() {
        return core;
    }

    public Upstream getUpstream() {
        return upstream;
    }

    public Platform getPlatform() {
        return platform;
    }

    /**
     * THE Rundeck — the one AutoOps runs itself, behind the product.
     *
     * <p>This is the white-label model and it is deliberately not a database
     * row. A tenant never sees this URL, never holds this token, and has no
     * screen that could leak either: the console shows Jobs and Executions with
     * AutoOps branding, and the engine underneath is an implementation detail.
     *
     * <p>Because ONE server serves every tenant, the isolation boundary moves
     * from "a credential per customer" to "a Rundeck project per AutoOps
     * project", provisioned here and named from the JWT's tenant claim. That
     * name is never accepted from a request — see {@code ProjectProvisioner}.
     */
    public static class Platform {

        /** e.g. http://rundeck:4440 on the compose network. */
        private String url = "http://rundeck:4440";

        /** Rundeck API token with admin rights (it provisions projects). */
        private String apiToken = "";

        private int apiVersion = 41;

        /**
         * Prefix for every project this platform creates. Makes the AutoOps
         * projects obvious in a Rundeck that might also hold hand-made ones,
         * and gives an operator a safe wildcard for ACLs.
         */
        private String projectPrefix = "autoops";

        /**
         * How long a single step may run before AutoOps stops waiting and
         * aborts the Rundeck execution. Mirrors job-service's hard cap: a step
         * that outlives it used to be force-killed with its whole process tree,
         * and losing that ceiling would let one runaway job hold a slot forever.
         */
        private Duration stepTimeout = Duration.ofMinutes(10);

        /** Gap between polls while waiting for a step's execution to finish. */
        private Duration pollInterval = Duration.ofSeconds(2);

        public String getUrl() {
            return url;
        }

        public void setUrl(String url) {
            this.url = url;
        }

        public String getApiToken() {
            return apiToken;
        }

        public void setApiToken(String apiToken) {
            this.apiToken = apiToken;
        }

        public int getApiVersion() {
            return apiVersion;
        }

        public void setApiVersion(int apiVersion) {
            this.apiVersion = apiVersion;
        }

        public String getProjectPrefix() {
            return projectPrefix;
        }

        public void setProjectPrefix(String projectPrefix) {
            this.projectPrefix = projectPrefix;
        }

        public Duration getStepTimeout() {
            return stepTimeout;
        }

        public void setStepTimeout(Duration stepTimeout) {
            this.stepTimeout = stepTimeout;
        }

        public Duration getPollInterval() {
            return pollInterval;
        }

        public void setPollInterval(Duration pollInterval) {
            this.pollInterval = pollInterval;
        }
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

    /**
     * Bounds on calls OUT to a customer's own Rundeck. That server is not ours:
     * it can be slow, down, or answering with a gigabyte of log. Every limit
     * here exists so one bad upstream cannot take this service with it.
     */
    public static class Upstream {

        private Duration connectTimeout = Duration.ofSeconds(5);

        private Duration readTimeout = Duration.ofSeconds(20);

        /** Rundeck's {@code /api/{version}/...} segment when a row has none. */
        private int defaultApiVersion = 41;

        /** Cap on lines relayed per log poll. */
        private int maxLogLines = 500;

        /**
         * Whether a plain {@code http://} upstream may be saved. The API token
         * rides on every request, so cleartext hands fleet control to anyone on
         * the path. True in dev (a laptop Rundeck has no certificate), and the
         * prod profile forces it false.
         */
        private boolean allowInsecure = true;

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

        public int getDefaultApiVersion() {
            return defaultApiVersion;
        }

        public void setDefaultApiVersion(int defaultApiVersion) {
            this.defaultApiVersion = defaultApiVersion;
        }

        public int getMaxLogLines() {
            return maxLogLines;
        }

        public void setMaxLogLines(int maxLogLines) {
            this.maxLogLines = maxLogLines;
        }

        public boolean isAllowInsecure() {
            return allowInsecure;
        }

        public void setAllowInsecure(boolean allowInsecure) {
            this.allowInsecure = allowInsecure;
        }
    }
}
