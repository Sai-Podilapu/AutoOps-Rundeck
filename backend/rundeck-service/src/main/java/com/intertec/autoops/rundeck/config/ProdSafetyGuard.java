package com.intertec.autoops.rundeck.config;

import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Refuses to start with an unsafe production configuration (same convention as
 * core-service, workflow-service and auth-service).
 *
 * <p>This service holds credentials that grant COMMAND EXECUTION on a
 * customer's own fleet — a Rundeck API token is not read access to an account,
 * it is the ability to run a job on every node that job targets. Two of the
 * checks below exist for that reason and have no analogue in the other
 * services: a dev encryption key means the tokens in the database are
 * effectively cleartext, and an insecure upstream means the token is on the
 * wire in cleartext on every single call.
 */
@Component
public class ProdSafetyGuard {

    private static final Logger log = LoggerFactory.getLogger(ProdSafetyGuard.class);

    /** The value shipped in backend/rundeck-runtime/tokens.properties. */
    private static final String DEV_PLATFORM_TOKEN = "autoops-platform-token";

    private final Environment environment;
    private final RundeckProperties properties;

    public ProdSafetyGuard(Environment environment, RundeckProperties properties) {
        this.environment = environment;
        this.properties = properties;
    }

    @PostConstruct
    public void verifyProdConfiguration() {
        List<String> profiles = Arrays.asList(environment.getActiveProfiles());
        if (!profiles.contains("prod")) {
            return;
        }

        List<String> problems = new ArrayList<>();
        if (profiles.contains("dev")) {
            problems.add("the 'dev' profile (local database defaults) is active alongside prod");
        }
        if ("autoops".equals(environment.getProperty("spring.datasource.password"))) {
            problems.add("DB_PASSWORD is still the development default");
        }
        if (properties.getJwksUri().contains("localhost")) {
            problems.add("AUTH_JWKS_URI still points at localhost");
        }
        if (properties.getSubscription().getBaseUrl().contains("localhost")) {
            problems.add("SUBSCRIPTION_SERVICE_URL still points at localhost");
        }
        if (properties.getSubscription().isEntitlementFailOpen()) {
            problems.add("ENTITLEMENT_FAIL_OPEN=true would skip subscription gating in prod");
        }
        if (properties.getCore().getBaseUrl().contains("localhost")) {
            problems.add("CORE_SERVICE_URL still points at localhost");
        }
        if (RundeckProperties.DEV_INTERNAL_TOKEN.equals(properties.getInternalToken())) {
            problems.add("RUNDECK_INTERNAL_TOKEN is still the development default — anyone who "
                    + "can reach /internal could dispatch a job on any tenant's fleet");
        }
        if (RundeckProperties.DEV_INTERNAL_TOKEN.equals(properties.getCore().getInternalToken())) {
            problems.add("CORE_INTERNAL_TOKEN is still the development default");
        }
        if (RundeckProperties.DEV_CREDENTIAL_KEY.equals(properties.getCredentialKey())) {
            problems.add("RUNDECK_CRED_KEY is still the development default — every stored "
                    + "Rundeck API token would be decryptable by anyone holding this source");
        }
        if (properties.getUpstream().isAllowInsecure()) {
            problems.add("RUNDECK_ALLOW_INSECURE=true would let an http:// upstream be used, "
                    + "putting a fleet-wide API token on the wire in cleartext");
        }
        // The engine executes every job for every tenant. Its token is the
        // single most valuable secret on the platform.
        if (properties.getPlatform().getApiToken() == null
                || properties.getPlatform().getApiToken().isBlank()) {
            problems.add("RUNDECK_API_TOKEN is unset — the execution engine is unreachable "
                    + "and no job in any tenant could run");
        }
        if (DEV_PLATFORM_TOKEN.equals(properties.getPlatform().getApiToken())) {
            problems.add("RUNDECK_API_TOKEN is still the development default "
                    + "(" + DEV_PLATFORM_TOKEN + ") — it is admin on the engine that runs "
                    + "every tenant's jobs, and it ships in this repository");
        }

        if (!problems.isEmpty()) {
            throw new IllegalStateException(
                    "Refusing to start with unsafe prod configuration: " + String.join("; ", problems));
        }
        log.info("Prod safety checks passed");
    }
}
