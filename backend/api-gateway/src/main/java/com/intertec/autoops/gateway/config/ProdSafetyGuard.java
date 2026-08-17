package com.intertec.autoops.gateway.config;

import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Refuses to start with an unsafe production configuration. The gateway's
 * development defaults all point at localhost (JWKS, routes, CORS origins) —
 * none of them may survive into prod silently.
 */
@Component
public class ProdSafetyGuard {

    private static final Logger log = LoggerFactory.getLogger(ProdSafetyGuard.class);

    private final Environment environment;
    private final GatewayProperties properties;

    public ProdSafetyGuard(Environment environment, GatewayProperties properties) {
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
            problems.add("the 'dev' profile is active alongside prod");
        }
        if (properties.getJwksUri().contains("localhost")) {
            problems.add("AUTH_JWKS_URI still points at localhost");
        }
        for (String origin : properties.getCorsAllowedOrigins()) {
            if (origin.contains("localhost")) {
                problems.add("CORS_ALLOWED_ORIGINS still contains the development origin " + origin);
            }
        }
        // Route targets are bound from YAML as an indexed list.
        for (int i = 0; ; i++) {
            String uri = environment.getProperty("spring.cloud.gateway.mvc.routes[" + i + "].uri");
            if (uri == null) {
                break;
            }
            if (uri.contains("localhost")) {
                String id = environment.getProperty("spring.cloud.gateway.mvc.routes[" + i + "].id");
                problems.add("route '" + id + "' still targets localhost (" + uri + ")");
            }
        }

        if (!problems.isEmpty()) {
            throw new IllegalStateException(
                    "Refusing to start with unsafe prod configuration: " + String.join("; ", problems));
        }
        log.info("Prod safety checks passed");
    }
}