package com.intertec.autoops.workflow.config;

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
 * core-service and auth-service). Development defaults must never survive into
 * prod silently.
 *
 * <p>This service owns workflow DEFINITIONS — the graph that says what a
 * tenant's automation does. Runs, approvals and audit live in core-service and
 * are reached over a shared-secret internal API. A dev token left in place lets
 * anyone who can reach the service rewrite what a tenant's automation does, and
 * the change is indistinguishable from a legitimate edit once it is saved.
 */
@Component
public class ProdSafetyGuard {

    private static final Logger log = LoggerFactory.getLogger(ProdSafetyGuard.class);

    private final Environment environment;
    private final WorkflowProperties properties;

    public ProdSafetyGuard(Environment environment, WorkflowProperties properties) {
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
        if (properties.getAgent().getBaseUrl().contains("localhost")) {
            problems.add("AGENT_SERVICE_URL still points at localhost");
        }
        if (WorkflowProperties.DEV_INTERNAL_TOKEN.equals(properties.getInternalToken())) {
            problems.add("WORKFLOW_INTERNAL_TOKEN is still the development default — anyone who "
                    + "can reach /internal could rewrite any tenant's workflow definitions");
        }
        if (WorkflowProperties.DEV_INTERNAL_TOKEN.equals(properties.getCore().getInternalToken())) {
            problems.add("CORE_INTERNAL_TOKEN is still the development default");
        }
        if (WorkflowProperties.DEV_INTERNAL_TOKEN.equals(properties.getAgent().getInternalToken())) {
            problems.add("AGENT_INTERNAL_TOKEN is still the development default");
        }

        if (!problems.isEmpty()) {
            throw new IllegalStateException(
                    "Refusing to start with unsafe prod configuration: " + String.join("; ", problems));
        }
        log.info("Prod safety checks passed");
    }
}
