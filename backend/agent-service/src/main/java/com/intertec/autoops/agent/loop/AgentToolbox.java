package com.intertec.autoops.agent.loop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.agent.client.AutomationClient;
import com.intertec.autoops.agent.client.ToolTargetClient;
import com.intertec.autoops.agent.domain.Agent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Turns an agent's allow-list into the tools a model is allowed to see, and
 * turns a tool name the model came back with into the target it authorises.
 *
 * <p><strong>This is the enforcement point.</strong> The model can emit any
 * tool name it likes — a hallucinated one, one it saw in a previous run, one
 * from its training data. {@link #resolve} answers ONLY from the map built out
 * of this agent's own allow-list, so an unknown name is a tool error the model
 * is told about, never a lookup that goes and finds something.
 *
 * <p>Names are derived from the target rather than free text: {@code job_14}
 * and {@code workflow_3} are unique by construction and impossible to collide
 * or spoof. The human name goes in the DESCRIPTION, which is what the model
 * actually reads.
 */
@Component
public class AgentToolbox {

    private static final Logger log = LoggerFactory.getLogger(AgentToolbox.class);

    private final ObjectMapper objectMapper;
    private final ToolTargetClient toolTargets;
    private final AutomationClient automations;

    public AgentToolbox(ObjectMapper objectMapper, ToolTargetClient toolTargets,
                        AutomationClient automations) {
        this.objectMapper = objectMapper;
        this.toolTargets = toolTargets;
        this.automations = automations;
    }

    /** One entry of the allow-list, resolved and ready to invoke. */
    public record Tool(String name, String type, Long targetId, String targetName) {
    }

    /**
     * @param specs   what the model is shown
     * @param byName  what a returned tool name resolves to — the allow-list,
     *                and nothing else
     * @param skipped entries that could not be offered, with the reason. Kept
     *                so the run can SAY a tool was unavailable instead of the
     *                agent silently behaving as though it never had one.
     */
    public record Toolbox(List<ToolSpec> specs, Map<String, Tool> byName, List<String> skipped) {

        public Tool resolve(String name) {
            return byName.get(name);
        }

        public boolean isEmpty() {
            return specs.isEmpty();
        }
    }

    /**
     * Builds the toolbox for one run.
     *
     * <p>Every entry is re-validated against its owning service even though it
     * was validated when the agent was saved. A job can be deleted, moved to
     * another project, or handed to another tenant between those two moments,
     * and the allow-list is a list of IDS — stale ids are exactly how an agent
     * would end up pointed at something that is no longer the thing it was
     * granted.
     */
    public Toolbox build(Agent agent) {
        List<ToolSpec> specs = new ArrayList<>();
        Map<String, Tool> byName = new LinkedHashMap<>();
        List<String> skipped = new ArrayList<>();

        for (Ref ref : parse(agent.getTools())) {
            if ("WORKFLOW".equals(ref.type())) {
                addWorkflow(agent, ref, specs, byName, skipped);
            } else {
                addJob(agent, ref, specs, byName, skipped);
            }
        }
        return new Toolbox(List.copyOf(specs), Map.copyOf(byName), List.copyOf(skipped));
    }

    private void addJob(Agent agent, Ref ref, List<ToolSpec> specs, Map<String, Tool> byName,
                        List<String> skipped) {
        ToolTargetClient.Target target = toolTargets
                .findJob(agent.getTenantId(), ref.id()).orElse(null);
        if (target == null || !agent.getProjectId().equals(target.projectId())) {
            skipped.add("Job #" + ref.id() + " is no longer available to this agent.");
            return;
        }

        String name = "job_" + ref.id();
        // A job carries no declared parameter form — it is a saved definition,
        // run as it stands. Advertising arguments it cannot accept would
        // invite the model to pass some and then quietly drop them.
        specs.add(new ToolSpec(name,
                "Run the automation job \"" + target.name() + "\". It runs its saved "
                        + "definition; it takes no arguments. Returns the run outcome and log.",
                ToolSpec.objectSchema(Map.of(), List.of())));
        byName.put(name, new Tool(name, "JOB", ref.id(), target.name()));
    }

    private void addWorkflow(Agent agent, Ref ref, List<ToolSpec> specs, Map<String, Tool> byName,
                             List<String> skipped) {
        ToolTargetClient.Target target = toolTargets
                .findWorkflow(agent.getTenantId(), ref.id()).orElse(null);
        if (target == null || !agent.getProjectId().equals(target.projectId())) {
            skipped.add("Workflow #" + ref.id() + " is no longer available to this agent.");
            return;
        }

        AutomationClient.WorkflowInputs inputs =
                automations.workflowInputs(agent.getTenantId(), ref.id());
        if (inputs.error() != null && !inputs.error().isBlank()) {
            // Left out rather than offered broken. A tool the model can see is
            // a tool it will eventually call, and one that fails on every call
            // wastes steps and teaches it nothing.
            skipped.add("Workflow \"" + target.name() + "\" is not runnable: " + inputs.error());
            return;
        }

        Map<String, Map<String, Object>> properties = new LinkedHashMap<>();
        List<String> required = new ArrayList<>();
        for (AutomationClient.InputField field : inputs.fields()) {
            properties.put(field.variable(), schemaFor(field));
            if (field.required()) {
                required.add(field.variable());
            }
        }

        String name = "workflow_" + ref.id();
        specs.add(new ToolSpec(name,
                "Run the workflow \"" + target.name() + "\"."
                        + (properties.isEmpty() ? " It takes no arguments." : "")
                        + " Returns the run outcome and log.",
                ToolSpec.objectSchema(properties, required)));
        byName.put(name, new Tool(name, "WORKFLOW", ref.id(), target.name()));
    }

    /**
     * Dify's field types mapped to JSON Schema.
     *
     * <p>Everything that is not explicitly a number or a fixed choice becomes
     * a string. That is not laziness: Dify's {@code paragraph}, {@code text-input}
     * and file types all arrive as text on the wire, and inventing a richer
     * type here would produce arguments the workflow cannot read.
     */
    private Map<String, Object> schemaFor(AutomationClient.InputField field) {
        Map<String, Object> schema = new LinkedHashMap<>();
        String type = field.type() == null ? "" : field.type().toLowerCase(Locale.ROOT);

        if (type.contains("number")) {
            schema.put("type", "number");
        } else if (type.contains("boolean")) {
            // Typed, not stringified. A switch offered as a string invites the
            // model to send "false", which is a non-empty string and therefore
            // true to anything that tests it loosely — the wrong answer to give
            // a flag whose whole job is to gate a destructive action.
            schema.put("type", "boolean");
        } else {
            schema.put("type", "string");
        }
        if (field.options() != null && !field.options().isEmpty()) {
            // A select field's options ARE the contract. Passing anything else
            // fails inside Dify with a message the model cannot act on, so the
            // choice is stated up front where it can be respected.
            schema.put("enum", field.options());
        }
        String label = field.label() == null || field.label().isBlank()
                ? field.variable() : field.label();
        schema.put("description", label);
        return schema;
    }

    // -------------------------------------------------------- allow-list ---

    private record Ref(String type, Long id) {
    }

    /**
     * Unreadable JSON yields an EMPTY list, not an exception. A corrupt
     * allow-list must leave an agent with no tools — the safe failure — rather
     * than blocking the run in a way someone might be tempted to work around.
     */
    private List<Ref> parse(String tools) {
        if (tools == null || tools.isBlank()) {
            return List.of();
        }
        try {
            JsonNode root = objectMapper.readTree(tools);
            if (!root.isArray()) {
                return List.of();
            }
            Set<Ref> unique = new LinkedHashSet<>();
            for (JsonNode entry : root) {
                String type = entry.path("type").asText("JOB").toUpperCase(Locale.ROOT);
                long id = entry.path("id").asLong(0);
                if (id > 0) {
                    unique.add(new Ref("WORKFLOW".equals(type) ? "WORKFLOW" : "JOB", id));
                }
            }
            return List.copyOf(unique);
        } catch (Exception ex) {
            log.warn("Unreadable tools JSON on an agent — running it with no tools: {}",
                    ex.getMessage());
            return List.of();
        }
    }
}
