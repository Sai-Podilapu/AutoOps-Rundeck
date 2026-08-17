package com.intertec.autoops.workflow.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.Set;

/**
 * The rule for "is this workflow complex enough to need an admin sign-off": at
 * least {@code rules.nodeThreshold()} nodes, or any node whose type is in
 * {@code rules.riskyTypes()} — infrastructure-grade steps touch real cloud
 * resources, so a fat-fingered run hurts. Node type extraction mirrors the
 * execution engine: {@code type} falls back to the designer's {@code id}.
 *
 * <p>This logic is DUPLICATED in core-service, which still owns approvals and
 * has to make the same judgement when it intercepts a run. It takes only
 * (definition, nodeCount, rules) so the two copies cannot drift on anything
 * but the arithmetic — and the tenant's rules themselves live in exactly one
 * place, core-service's {@code approval_settings}.
 */
public final class WorkflowComplexity {

    /** Platform default; per-tenant override lives in approval_settings. */
    public static final int NODE_THRESHOLD = 5;

    /**
     * Platform default risky set ("k8s" is the workflow designer's kubernetes
     * node type; jobs use "kubernetes").
     */
    public static final Set<String> RISKY_TYPES =
            Set.of("terraform", "kubernetes", "k8s", "awslambda", "azurefn", "ssh");

    /** Effective per-tenant knobs, fetched from core-service. */
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
