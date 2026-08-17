package com.intertec.autoops.core.config;

import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Refuses to start with an unsafe production configuration (same convention
 * as auth-service). Development defaults (DB password, localhost JWKS or
 * subscription URL, fail-open entitlements) must never survive into prod
 * silently.
 */
@Component
public class ProdSafetyGuard {

    private static final Logger log = LoggerFactory.getLogger(ProdSafetyGuard.class);

    private final Environment environment;
    private final CoreProperties properties;

    public ProdSafetyGuard(Environment environment, CoreProperties properties) {
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
        if (CoreProperties.Cloud.DEV_KEY.equals(properties.getCloud().getCredentialKey())) {
            problems.add("CLOUD_CRED_KEY is still the development default — cloud credentials would be trivially decryptable");
        }
        if ("dev-internal-token".equals(properties.getExecution().getJobServiceToken())
                && "remote".equals(properties.getExecution().getMode())) {
            problems.add("JOB_INTERNAL_TOKEN is still the development default");
        }
        if (CoreProperties.Subscription.DEV_INTERNAL_TOKEN.equals(
                properties.getSubscription().getInternalToken())) {
            problems.add("SUBSCRIPTION_INTERNAL_TOKEN is still the development default");
        }

        if (!problems.isEmpty()) {
            throw new IllegalStateException(
                    "Refusing to start with unsafe prod configuration: " + String.join("; ", problems));
        }
        log.info("Prod safety checks passed");
    }
}
