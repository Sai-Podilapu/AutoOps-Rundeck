package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.Set;

/**
 * "Is this workflow complex enough to need an admin sign-off": COMPLEX when
 * it has at least {@code rules.nodeThreshold()} nodes, or contains any node
 * whose type is in {@code rules.riskyTypes()} — infrastructure-grade steps
 * touch real cloud resources, so a fat-fingered run hurts. Both knobs are
 * per-tenant (ApprovalSettingsService, which still lives here); the platform
 * defaults below apply when a tenant has not overridden them. Node type
 * extraction mirrors the execution engine: {@code type} falls back to the
 * designer's {@code id}.
 *
 * <p>Workflows themselves moved to workflow-service, so this takes the
 * definition and node count as DATA rather than an entity — the same shape
 * the twin copy in workflow-service uses, so the two cannot drift apart on
 * anything but the arithmetic.
 */
public final class WorkflowComplexity {

    /** Platform default; per-tenant override lives in approval_settings. */
    public static final int NODE_THRESHOLD = 5;

    /**
     * Platform default risky set ("k8s" is the workflow designer's kubernetes
     * node type; jobs use "kubernetes"). Per-tenant override in
     * approval_settings.risky_types.
     */
    public static final Set<String> RISKY_TYPES =
            Set.of("terraform", "kubernetes", "k8s", "awslambda", "azurefn", "ssh");

    /** Effective per-tenant knobs, resolved by ApprovalSettingsService. */
    public record ComplexityRules(int nodeThreshold, Set<String> riskyTypes) {
        public static final ComplexityRules PLATFORM_DEFAULTS =
                new ComplexityRules(NODE_THRESHOLD, RISKY_TYPES);
    }

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private WorkflowComplexity() {
    }

    public static boolean isComplex(String definition, int nodeCount, ComplexityRules rules) {
        return nodeCount >= rules.nodeThreshold()
                || containsRiskyNode(definition, rules.riskyTypes());
    }

    static boolean containsRiskyNode(String definition, Set<String> riskyTypes) {
        if (definition == null || definition.isBlank() || riskyTypes.isEmpty()) {
            return false;
        }
        try {
            JsonNode nodes = MAPPER.readTree(definition).path("nodes");
            for (JsonNode node : nodes) {
                String type = node.path("type").asText(node.path("id").asText(""));
                if (riskyTypes.contains(type.toLowerCase())) {
                    return true;
                }
            }
        } catch (Exception ex) {
            // Unparseable definition: nothing will execute either — not risky.
        }
        return false;
    }
}
