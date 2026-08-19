package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.intertec.autoops.core.client.AgentClient;
import com.intertec.autoops.core.client.EntitlementClient;
import com.intertec.autoops.core.client.WorkflowClient;
import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.domain.LibraryItem;
import com.intertec.autoops.core.domain.Project;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.LibraryItemRepository;
import com.intertec.autoops.core.repo.ProjectRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.HashMap;

/**
 * Rolling a platform catalog item out to customers — the provider's
 * distribution channel, and the only way a workflow or agent comes to exist in
 * a tenant's workspace.
 *
 * <p><b>The check that matters.</b> workflow-service and agent-service both
 * skip the project round trip on the rollout path (they would otherwise call
 * back into this service from inside its own request). That makes THIS class
 * solely responsible for proving the target project belongs to the target
 * tenant. {@link #resolveProject} is that proof, and it reads the project by
 * (id, tenantId) together — never by id alone — so a mistyped or hostile
 * project id resolves to nothing rather than to another customer's project.
 *
 * <p>Rollout is deliberately NOT atomic across tenants: ten customers, ten
 * independent writes. One failing (an expired plan, a name clash) must not
 * roll back the nine that worked, so failures are collected and reported per
 * tenant instead of thrown.
 */
@Service
public class RolloutService {

    private static final Logger log = LoggerFactory.getLogger(RolloutService.class);

    private final LibraryItemRepository libraryRepository;
    private final ProjectRepository projectRepository;
    private final WorkflowClient workflowClient;
    private final AgentClient agentClient;
    private final EntitlementClient entitlementClient;
    private final AuditService auditService;
    private final ObjectMapper objectMapper;

    public RolloutService(LibraryItemRepository libraryRepository,
                          ProjectRepository projectRepository,
                          WorkflowClient workflowClient,
                          AgentClient agentClient,
                          EntitlementClient entitlementClient,
                          AuditService auditService,
                          ObjectMapper objectMapper) {
        this.libraryRepository = libraryRepository;
        this.projectRepository = projectRepository;
        this.workflowClient = workflowClient;
        this.agentClient = agentClient;
        this.entitlementClient = entitlementClient;
        this.auditService = auditService;
        this.objectMapper = objectMapper;
    }

    /** One customer to deliver to: which tenant, and into which project. */
    public record Target(String tenantId, Long projectId) {
    }

    /** Per-target outcome, so a partial rollout reports honestly. */
    public record Delivery(String tenantId, Long projectId, Long createdId, String error) {
        static Delivery ok(String tenantId, Long projectId, Long createdId) {
            return new Delivery(tenantId, projectId, createdId, null);
        }

        static Delivery failed(String tenantId, Long projectId, String error) {
            return new Delivery(tenantId, projectId, null, error);
        }

        public boolean succeeded() {
            return error == null;
        }
    }

    public record RolloutResult(Long catalogId, String title, String type,
                                int delivered, int failed, List<Delivery> deliveries) {
    }

    /**
     * Deliver one catalog item to every listed target.
     *
     * @param accessToken the PROVIDER's token — passed through so the
     *                    RECEIVING tenant's plan gate still runs downstream
     */
    @Transactional
    public RolloutResult rollOut(String actor, String accessToken, Long catalogId,
                                 List<Target> targets) {
        LibraryItem item = libraryRepository.findByIdAndTenantIdIsNull(catalogId)
                .orElseThrow(() -> CoreException.notFound("template_not_found",
                        "No such catalog item"));
        if (item.getType() == LibraryItem.Type.SCRIPT) {
            throw CoreException.badRequest("script_not_rollable",
                    "Scripts are offered through the library for customers to import, "
                            + "not rolled out. Roll out a workflow or an agent.");
        }
        if (targets == null || targets.isEmpty()) {
            throw CoreException.badRequest("no_targets", "Choose at least one customer");
        }

        List<Delivery> deliveries = new ArrayList<>();
        for (Target target : targets) {
            try {
                Project project = resolveProject(target);
                requireLiveSubscription(target.tenantId());
                Long createdId = item.getType() == LibraryItem.Type.WORKFLOW
                        ? rollOutWorkflow(item, target, project, actor, accessToken)
                        : rollOutAgent(item, target, project, actor, accessToken);
                deliveries.add(Delivery.ok(target.tenantId(), project.getId(), createdId));
                auditService.record(CoreAuditEventType.TEMPLATE_ROLLED_OUT, target.tenantId(),
                        actor, project.getId(), item.getType().name(), createdId,
                        item.getTitle(), "rolled out from catalog item " + catalogId);
            } catch (CoreException ex) {
                // Collected, not thrown: one customer's failure must not undo
                // the deliveries that already succeeded.
                log.warn("Rollout of catalog item {} to tenant {} failed: {}",
                        catalogId, target.tenantId(), ex.getMessage());
                deliveries.add(Delivery.failed(target.tenantId(), target.projectId(),
                        ex.getMessage()));
            }
        }

        int delivered = (int) deliveries.stream().filter(Delivery::succeeded).count();
        log.info("Catalog item {} ('{}') rolled out to {}/{} customers",
                catalogId, item.getTitle(), delivered, deliveries.size());
        return new RolloutResult(catalogId, item.getTitle(),
                item.getType().name().toLowerCase(java.util.Locale.ROOT),
                delivered, deliveries.size() - delivered, deliveries);
    }

    /**
     * The tenant-boundary proof. Reading by (id, tenantId) together is the
     * whole point: by id alone, a provider could deliver into a project that
     * belongs to someone else entirely.
     */
    private Project resolveProject(Target target) {
        if (target.tenantId() == null || target.tenantId().isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Each target needs a tenantId");
        }
        if (target.projectId() == null) {
            throw CoreException.badRequest("missing_project",
                    "Choose which project to deliver into");
        }
        return projectRepository.findByIdAndTenantId(target.projectId(), target.tenantId())
                .orElseThrow(() -> CoreException.notFound("project_not_found",
                        "That project does not belong to this customer"));
    }

    /**
     * The RECEIVING customer must have a live subscription.
     *
     * <p>This has to be checked here, by tenant id, because the plan gate
     * downstream reads the tenant from the bearer token — and on a rollout
     * that token is the PROVIDER's. Left to itself, workflow-service would
     * evaluate the provider's own plan and refuse every delivery with
     * {@code no_subscription}, which is exactly what it did before this check
     * existed.
     */
    private void requireLiveSubscription(String tenantId) {
        EntitlementClient.Decision decision = entitlementClient.checkTenant(tenantId);
        if (!decision.entitled()) {
            throw CoreException.forbidden(
                    decision.reason() == null ? "no_subscription" : decision.reason(),
                    "This customer has no active subscription");
        }
    }

    private Long rollOutWorkflow(LibraryItem item, Target target, Project project,
                                 String actor, String accessToken) {
        WorkflowClient.WorkflowView created = workflowClient.rollOut(target.tenantId(), actor,
                accessToken, project.getId(), item.getId(), item.getTitle(),
                item.getDefinition());
        return created != null ? created.id() : null;
    }

    /**
     * An AGENT catalog item stores its definition in the same column a workflow
     * stores its canvas in. There are two shapes, and the difference is where
     * the product lives.
     *
     * <p>A JSON agent carries its persona with it:
     * {@code {"description":…,"model":…,"instructions":…,"tools":[…]}} — which
     * means the persona is physically copied into every customer's database,
     * protected only by no API exposing it.
     *
     * <p>A PYTHON agent carries a REFERENCE:
     * {@code {"kind":"PYTHON","ref":"linux.server_health_check","version":"1.0.0",…}}.
     * Its persona, prompts and phase graph live in agent-runtime's image and
     * are never delivered anywhere. That is strictly stronger sealing, and it
     * is why {@code instructions} is absent rather than empty on that path.
     *
     * <p>The allow-list travels as JSON text either way, because that is what
     * agent-service re-validates against the destination project — this service
     * never decides what an agent may touch.
     */
    private Long rollOutAgent(LibraryItem item, Target target, Project project,
                              String actor, String accessToken) {
        JsonNode spec;
        try {
            spec = objectMapper.readTree(item.getDefinition());
        } catch (Exception ex) {
            throw CoreException.badRequest("invalid_definition",
                    "This agent's definition is not valid JSON");
        }
        String tools = resolveTools(spec.path("tools"), target, project);
        boolean python = "PYTHON".equalsIgnoreCase(text(spec, "kind", null));
        AgentClient.RolledOutAgent created = agentClient.rollOut(target.tenantId(), actor,
                accessToken, project.getId(), item.getId(), item.getTitle(),
                text(spec, "description", item.getDescription()),
                text(spec, "model", null),
                // Exactly one of these is ever populated. A Python agent with
                // instructions would mean the persona leaked into the catalog
                // row; a JSON agent with a graph ref would mean the runtime was
                // asked for a module that does not exist.
                python ? null : text(spec, "instructions", null),
                python ? text(spec, "ref", null) : null,
                python ? text(spec, "version", null) : null,
                tools);
        return created != null ? created.id() : null;
    }

    /**
     * Turns the catalog's allow-list of stable {@code ref}s into the numeric
     * ids the RECEIVING project actually uses.
     *
     * <p>A catalog agent cannot carry ids: workflow #42 in the provider's
     * workspace is a different automation in every customer's, and
     * {@code AgentService.normalizeTools} rightly refuses an id that is not in
     * the destination project. So the allow-list travels as {@code ref} — the
     * key each published workflow stores in its own definition and keeps
     * through delivery — and is resolved here, per tenant, against the copies
     * that project already holds.
     *
     * <p><b>Fails rather than thins the list.</b> If a referenced workflow has
     * not been delivered to this project yet, this tenant's delivery fails with
     * a message naming what is missing. Delivering the agent with that tool
     * quietly dropped would hand the customer something that looks complete and
     * silently cannot do part of its job.
     */
    private String resolveTools(JsonNode tools, Target target, Project project) {
        if (!tools.isArray() || tools.isEmpty()) {
            return null;
        }

        // One listing serves every ref in the allow-list.
        Map<String, Long> byRef = new HashMap<>();
        for (WorkflowClient.WorkflowView delivered
                : workflowClient.listByProject(target.tenantId(), project.getId())) {
            String ref = refIn(delivered.definition());
            if (ref != null) {
                byRef.put(ref, delivered.id());
            }
        }

        ArrayNode resolved = objectMapper.createArrayNode();
        List<String> missing = new ArrayList<>();
        for (JsonNode tool : tools) {
            String type = tool.path("type").asText("WORKFLOW");
            String ref = tool.path("ref").asText(null);
            if (ref == null || ref.isBlank()) {
                throw CoreException.badRequest("unresolvable_tool",
                        "This agent's allow-list names a tool without a ref, so it cannot be "
                                + "resolved to anything in the customer's project");
            }
            if (!"WORKFLOW".equals(type)) {
                // Jobs are the customer's own and are never rolled out, so a
                // provider agent has no way to know their ids.
                throw CoreException.badRequest("unrollable_tool",
                        "A catalog agent can only use workflows; '" + ref + "' is a "
                                + type.toLowerCase(java.util.Locale.ROOT));
            }
            Long id = byRef.get(ref);
            if (id == null) {
                missing.add(ref);
                continue;
            }
            ObjectNode entry = resolved.addObject();
            entry.put("type", "WORKFLOW");
            entry.put("id", id);
            // Carried through delivery because the phased runtime hides
            // state-changing tools from the phase that is still gathering
            // evidence, and only the agent's AUTHOR knows which is which —
            // nothing in a workflow's own definition records whether running
            // it changes anything. Absent means mutating, which is the safe
            // way for this to be wrong: an unlabelled read-only tool goes
            // unused and is noticed, where an unlabelled destructive one would
            // be offered to exactly the phase that must not see it.
            entry.put("mutating", !tool.path("mutating").isBoolean()
                    || tool.path("mutating").asBoolean());
        }

        if (!missing.isEmpty()) {
            throw CoreException.badRequest("tool_not_delivered",
                    "Roll out " + String.join(", ", missing) + " to this project first — "
                            + "this agent cannot work without it");
        }
        return resolved.toString();
    }

    /** The stable key a published workflow carries through delivery. */
    private String refIn(String definition) {
        if (definition == null || definition.isBlank()) {
            return null;
        }
        try {
            JsonNode ref = objectMapper.readTree(definition).path("ref");
            return ref.isTextual() && !ref.asText().isBlank() ? ref.asText() : null;
        } catch (Exception ex) {
            return null; // unparseable: simply not a match for anything
        }
    }

    private static String text(JsonNode node, String field, String fallback) {
        JsonNode value = node.path(field);
        return value.isTextual() && !value.asText().isBlank() ? value.asText() : fallback;
    }
}
