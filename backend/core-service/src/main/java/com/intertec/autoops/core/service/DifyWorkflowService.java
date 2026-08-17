package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.client.DifyAppClient;
import com.intertec.autoops.core.config.DifyAppRegistry;
import com.intertec.autoops.core.exception.CoreException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The one place that turns a workflow <i>slug</i> into something usable — its
 * name, the form a customer has to fill in, and a run.
 *
 * <p><b>Why a slug and not a Dify app id.</b> A library item's
 * {@code definition} is rendered into the browser by the provider Library
 * dialog, so whatever goes in it is public to anyone who can open that screen.
 * The slug is a meaningless label; the {@code app-…} key it resolves to stays
 * in {@link DifyAppRegistry} on the server. See
 * {@link #slugIn(String)} for the definition shape.
 *
 * <p><b>Why the input form is read from Dify rather than stored.</b> Dify's
 * {@code /v1/parameters} is generated from the published workflow's start node.
 * Copying it into AutoOps at publish time would mean every edit in Dify
 * silently desynchronises the form the customer sees from the variables the
 * workflow actually reads — and the failure mode is a run that succeeds with
 * empty inputs, not an error.
 */
@Service
public class DifyWorkflowService {

    private static final Logger log = LoggerFactory.getLogger(DifyWorkflowService.class);

    /** The key a workflow library item carries instead of a canvas. */
    public static final String SLUG_FIELD = "difyWorkflow";

    private final DifyAppRegistry registry;
    private final DifyAppClient client;
    private final ObjectMapper objectMapper;

    public DifyWorkflowService(DifyAppRegistry registry, DifyAppClient client,
                               ObjectMapper objectMapper) {
        this.registry = registry;
        this.client = client;
        this.objectMapper = objectMapper;
    }

    /** One field of the published input form, flattened out of Dify's shape. */
    public record InputField(String variable, String label, String type, boolean required,
                             String defaultValue, List<String> options, Integer maxLength) {
    }

    /**
     * A runnable workflow as the provider sees it when choosing what to publish.
     * {@code error} is populated instead of the rest when that one key fails —
     * one revoked key must not blank the whole catalog.
     */
    public record CatalogEntry(String slug, String name, String description,
                               List<InputField> inputs, String error) {
    }

    /** Every workflow this platform holds a key for. Empty is a valid answer. */
    public List<CatalogEntry> catalog() {
        List<CatalogEntry> out = new ArrayList<>();
        for (String slug : registry.slugs()) {
            String key = registry.keyFor(slug).orElse(null);
            if (key == null) {
                continue;
            }
            try {
                JsonNode info = client.info(key);
                out.add(new CatalogEntry(slug,
                        info.path("name").asText(slug),
                        info.path("description").asText(""),
                        readInputs(client.parameters(key)), null));
            } catch (CoreException ex) {
                // Reported, not thrown: the provider needs to see WHICH key is
                // broken, and still be able to publish the ones that work.
                log.warn("Dify workflow '{}' could not be read: {}", slug, ex.getMessage());
                out.add(new CatalogEntry(slug, slug, null, List.of(), ex.getMessage()));
            }
        }
        return out;
    }

    /** The input form for one slug. Throws if no key is configured for it. */
    public List<InputField> inputsFor(String slug) {
        return readInputs(client.parameters(requireKey(slug)));
    }

    public DifyAppClient.RunOutcome run(String slug, Map<String, Object> inputs, String user) {
        return client.run(requireKey(slug), inputs, user);
    }

    /**
     * Rejects a run that is missing a required value BEFORE it reaches Dify.
     * Dify would otherwise run the workflow with the variable unset, which
     * usually succeeds and produces nonsense rather than failing.
     */
    public Map<String, Object> validate(String slug, Map<String, Object> supplied) {
        List<InputField> fields = inputsFor(slug);
        Map<String, Object> clean = new LinkedHashMap<>();
        List<String> missing = new ArrayList<>();
        for (InputField field : fields) {
            Object value = supplied == null ? null : supplied.get(field.variable());
            boolean blank = value == null || String.valueOf(value).isBlank();
            if (blank && field.defaultValue() != null && !field.defaultValue().isBlank()) {
                value = field.defaultValue();
                blank = false;
            }
            if (blank) {
                if (field.required()) {
                    missing.add(field.label() == null || field.label().isBlank()
                            ? field.variable() : field.label());
                }
                continue;
            }
            clean.put(field.variable(), value);
        }
        if (!missing.isEmpty()) {
            throw CoreException.badRequest("missing_inputs",
                    "Fill in: " + String.join(", ", missing));
        }
        return clean;
    }

    /**
     * The slug a workflow definition names, or null when the definition is a
     * plain {@code nodes[]} canvas. That null is what keeps every pre-existing
     * workflow running through job-service exactly as before.
     */
    public String slugIn(String definition) {
        if (definition == null || definition.isBlank()) {
            return null;
        }
        try {
            JsonNode slug = objectMapper.readTree(definition).path(SLUG_FIELD);
            return slug.isTextual() && !slug.asText().isBlank() ? slug.asText() : null;
        } catch (Exception ex) {
            return null; // unparseable: treat as a non-Dify definition
        }
    }

    public boolean hasKeyFor(String slug) {
        return registry.keyFor(slug).isPresent();
    }

    private String requireKey(String slug) {
        return registry.keyFor(slug).orElseThrow(() -> CoreException.serviceUnavailable(
                "dify_workflow_key_missing",
                "No Dify key is configured for workflow '" + slug + "'. Set DIFY_WF_"
                        + slug.toUpperCase(java.util.Locale.ROOT).replace('-', '_')
                        + " on core-service and restart it."));
    }

    /**
     * Dify's {@code user_input_form} is a list of single-key objects, where the
     * key IS the control type: {@code [{"text-input":{…}}, {"select":{…}}]}.
     * Flattened here so no caller has to know that shape.
     */
    private List<InputField> readInputs(JsonNode parameters) {
        List<InputField> fields = new ArrayList<>();
        if (parameters == null) {
            return fields;
        }
        for (JsonNode entry : parameters.path("user_input_form")) {
            Iterator<Map.Entry<String, JsonNode>> it = entry.fields();
            if (!it.hasNext()) {
                continue;
            }
            Map.Entry<String, JsonNode> control = it.next();
            JsonNode spec = control.getValue();
            String variable = spec.path("variable").asText("");
            if (variable.isBlank()) {
                continue; // unusable without a name to send it back under
            }
            List<String> options = new ArrayList<>();
            for (JsonNode option : spec.path("options")) {
                options.add(option.asText());
            }
            fields.add(new InputField(
                    variable,
                    spec.path("label").asText(variable),
                    normalizeType(control.getKey()),
                    spec.path("required").asBoolean(false),
                    spec.path("default").isMissingNode() || spec.path("default").isNull()
                            ? null : spec.path("default").asText(null),
                    options,
                    spec.path("max_length").isNumber() ? spec.path("max_length").asInt() : null));
        }
        return fields;
    }

    /** Dify's control names mapped onto the four the console can render. */
    private static String normalizeType(String difyControl) {
        return switch (difyControl == null ? "" : difyControl) {
            case "paragraph" -> "paragraph";
            case "select" -> "select";
            case "number" -> "number";
            default -> "text";
        };
    }
}
