package com.intertec.autoops.agent.config;

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
 * <p>The stakes here are specific to this service. The agent loop spends a
 * tenant's model budget and calls tools that touch their infrastructure, and it
 * reaches core-service and workflow-service over shared-secret internal APIs.
 * A dev token left in place means anyone who can reach those services can
 * dispatch automation as any tenant — the loop's own {@code max-steps} bound
 * does nothing about that, because the caller never goes through the loop.
 */
@Component
public class ProdSafetyGuard {

    private static final Logger log = LoggerFactory.getLogger(ProdSafetyGuard.class);

    private final Environment environment;
    private final AgentProperties properties;

    public ProdSafetyGuard(Environment environment, AgentProperties properties) {
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
        if (properties.getWorkflow().getBaseUrl().contains("localhost")) {
            problems.add("WORKFLOW_SERVICE_URL still points at localhost");
        }
        if (AgentProperties.DEV_INTERNAL_TOKEN.equals(properties.getInternalToken())) {
            problems.add("AGENT_INTERNAL_TOKEN is still the development default — anyone who "
                    + "can reach /internal could drive agent runs for any tenant");
        }
        if (AgentProperties.DEV_INTERNAL_TOKEN.equals(properties.getCore().getInternalToken())) {
            problems.add("CORE_INTERNAL_TOKEN is still the development default");
        }
        if (AgentProperties.DEV_INTERNAL_TOKEN.equals(properties.getWorkflow().getInternalToken())) {
            problems.add("WORKFLOW_INTERNAL_TOKEN is still the development default");
        }

        if (!problems.isEmpty()) {
            throw new IllegalStateException(
                    "Refusing to start with unsafe prod configuration: " + String.join("; ", problems));
        }
        log.info("Prod safety checks passed");
    }
}
