package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.exception.CoreException;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import java.util.regex.PatternSyntaxException;

/**
 * Checks a caller's answers against the input form a NATIVE workflow declares
 * for itself, before the run is created.
 *
 * <p><b>Why this is a security control, not a convenience.</b> A validated
 * value is substituted into a step's command line — an SSH target, a script
 * argument. The declared {@code pattern} is what stands between an operator
 * (or a model, or a direct API call) and arbitrary command injection on a
 * customer's server. Validating in the console alone would leave the API
 * unguarded, so the check lives here, on the path every run takes.
 *
 * <p><b>Fail closed.</b> An undeclared field is rejected rather than passed
 * through: a workflow that declares its whole contract cannot also accept
 * things it never asked for, and silently dropping an input the caller
 * believed mattered is worse than refusing it. A field whose {@code pattern}
 * will not compile rejects every value rather than accepting all of them.
 *
 * <p>Dify-backed workflows keep their own validation in
 * {@link DifyWorkflowService}; this is the native equivalent.
 */
@Service
public class NativeInputValidator {

    private final ObjectMapper objectMapper;

    public NativeInputValidator(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    /**
     * @return cleaned values keyed by variable, or null when this workflow
     *         declares no form at all — which the run row records differently
     *         from "a form was shown and left blank"
     */
    public Map<String, Object> validate(String definition, Map<String, Object> supplied) {
        List<JsonNode> fields = declaredFields(definition);
        if (fields.isEmpty()) {
            return null;
        }
        Map<String, Object> answers = supplied == null ? Map.of() : supplied;

        Map<String, JsonNode> byName = new LinkedHashMap<>();
        for (JsonNode field : fields) {
            byName.put(field.path("variable").asText(), field);
        }

        List<String> problems = new ArrayList<>();
        for (String name : answers.keySet()) {
            if (!byName.containsKey(name)) {
                problems.add("'" + name + "' is not an input this workflow accepts");
            }
        }

        Map<String, Object> clean = new LinkedHashMap<>();
        for (Map.Entry<String, JsonNode> entry : byName.entrySet()) {
            String name = entry.getKey();
            JsonNode field = entry.getValue();
            Object raw = answers.get(name);

            // A default only applies when the caller said nothing at all, and
            // it goes through exactly the same checks as a supplied value.
            // Two reasons: a default that violates its own field's rules is a
            // fault worth surfacing, and a default that skipped conversion
            // would reach the step as a different type than the same value
            // typed in by hand.
            if (isBlank(raw)) {
                if (!field.has("default")) {
                    if (isRequired(field, answers)) {
                        problems.add("'" + label(field) + "' is required");
                        continue;
                    }
                    // An optional field nobody filled in still has to APPEAR in
                    // the result. Leaving it out entirely means its
                    // {{placeholder}} survives substitution and the step is
                    // refused for "missing" values the form said were optional
                    // — which is exactly what an operator would call a bug.
                    // Empty is the answer: `-ProfileName ''` is what "use the
                    // host's IAM role" looks like on a command line.
                    clean.put(name, "");
                    continue;
                }
                raw = objectMapper.convertValue(field.get("default"), Object.class);
            }

            try {
                clean.put(name, checked(field, raw));
            } catch (IllegalArgumentException ex) {
                problems.add(ex.getMessage());
            }
        }

        if (!problems.isEmpty()) {
            throw CoreException.badRequest("invalid_inputs", String.join("; ", problems));
        }
        return clean;
    }

    /** True when a run of this definition needs its inputs checked here. */
    public boolean declaresForm(String definition) {
        return !declaredFields(definition).isEmpty();
    }

    /**
     * The form the console renders before a native workflow runs, in the same
     * shape a Dify-backed one produces — so the console asks the person the
     * same way whichever engine is behind the automation.
     *
     * <p>Every field the validator will later enforce is offered here. If the
     * two ever disagree the operator is asked for one thing and judged on
     * another, so both read the same {@code inputs[]} rather than keeping
     * separate ideas of the contract.
     */
    public List<DifyWorkflowService.InputField> formFor(String definition) {
        List<DifyWorkflowService.InputField> form = new ArrayList<>();
        for (JsonNode field : declaredFields(definition)) {
            List<String> options = new ArrayList<>();
            if (field.path("options").isArray()) {
                field.get("options").forEach(option -> options.add(option.asText()));
            }
            JsonNode defaultValue = field.get("default");
            form.add(new DifyWorkflowService.InputField(
                    field.path("variable").asText(),
                    label(field),
                    field.path("type").asText("string"),
                    field.path("required").asBoolean(false),
                    defaultValue == null || defaultValue.isNull()
                            ? null : defaultValue.asText(),
                    options,
                    null));
        }
        return form;
    }

    private List<JsonNode> declaredFields(String definition) {
        List<JsonNode> fields = new ArrayList<>();
        if (definition == null || definition.isBlank()) {
            return fields;
        }
        JsonNode inputs;
        try {
            inputs = objectMapper.readTree(definition).path("inputs");
        } catch (Exception ex) {
            return fields; // unparseable: no form to enforce
        }
        if (inputs.isArray()) {
            for (JsonNode field : inputs) {
                if (!field.path("variable").asText("").isBlank()) {
                    fields.add(field);
                }
            }
        }
        return fields;
    }

    /**
     * {@code requiredWhen} makes a field mandatory only for the answers that
     * need it — an approval reference matters when Execute is on, and asking
     * for one on a report-only run would train people to invent values.
     */
    private boolean isRequired(JsonNode field, Map<String, Object> answers) {
        if (field.path("required").asBoolean(false)) {
            return true;
        }
        JsonNode when = field.get("requiredWhen");
        if (when == null) {
            return false;
        }
        Object other = answers.get(when.path("field").asText());
        Object trigger = objectMapper.convertValue(when.get("equals"), Object.class);
        return String.valueOf(other).equalsIgnoreCase(String.valueOf(trigger));
    }

    private Object checked(JsonNode field, Object raw) {
        String name = label(field);
        String type = field.path("type").asText("string").toLowerCase(Locale.ROOT);
        String text = String.valueOf(raw);

        if (field.path("options").isArray()) {
            List<String> options = new ArrayList<>();
            field.get("options").forEach(option -> options.add(option.asText()));
            if (!options.contains(text)) {
                throw new IllegalArgumentException(
                        "'" + name + "' must be one of " + String.join(", ", options));
            }
            return text;
        }

        switch (type) {
            case "number" -> {
                double value;
                try {
                    value = Double.parseDouble(text);
                } catch (NumberFormatException ex) {
                    throw new IllegalArgumentException("'" + name + "' must be a number");
                }
                if (field.has("min") && value < field.get("min").asDouble()) {
                    throw new IllegalArgumentException(
                            "'" + name + "' must be at least " + field.get("min").asText());
                }
                if (field.has("max") && value > field.get("max").asDouble()) {
                    throw new IllegalArgumentException(
                            "'" + name + "' must be at most " + field.get("max").asText());
                }
                return value == Math.rint(value) ? (Object) (long) value : (Object) value;
            }
            case "boolean" -> {
                if (!text.equalsIgnoreCase("true") && !text.equalsIgnoreCase("false")) {
                    throw new IllegalArgumentException("'" + name + "' must be true or false");
                }
                return Boolean.parseBoolean(text);
            }
            default -> {
                if (field.has("pattern")) {
                    String regex = field.get("pattern").asText();
                    try {
                        if (!Pattern.compile(regex).matcher(text).matches()) {
                            throw new IllegalArgumentException(
                                    "'" + name + "' is not in the expected format");
                        }
                    } catch (PatternSyntaxException ex) {
                        // Refuse everything rather than accept everything: a
                        // broken guard must not read as an absent one.
                        throw new IllegalArgumentException(
                                "'" + name + "' cannot be validated — its declared pattern is "
                                        + "not a valid expression, so no value is accepted");
                    }
                }
                return text;
            }
        }
    }

    private static String label(JsonNode field) {
        String label = field.path("label").asText("");
        return label.isBlank() ? field.path("variable").asText() : label;
    }

    private static boolean isBlank(Object value) {
        return value == null || String.valueOf(value).isBlank();
    }
}
