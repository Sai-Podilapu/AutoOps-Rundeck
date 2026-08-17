package com.intertec.autoops.agent.loop;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A tool offered to the model, as a name, a description and a JSON Schema.
 *
 * <p>The description is the highest-leverage field here and is worth writing
 * properly: it is how the model decides WHETHER to call the tool at all, and a
 * vague one produces both misses and spurious calls. Say what the tool does,
 * when to reach for it, and - for anything that changes state - that it will
 * be gated.
 */
public record ToolSpec(String name, String description, Map<String, Object> inputSchema) {

    public ToolSpec {
        inputSchema = Map.copyOf(inputSchema);
    }

    /**
     * A schema of plain string/number properties.
     *
     * <p>{@code additionalProperties: false} is always set: without it a model
     * may invent extra fields, and the dispatcher would silently ignore them
     * while the model believes they took effect.
     */
    public static Map<String, Object> objectSchema(Map<String, Map<String, Object>> properties,
                                                   List<String> required) {
        Map<String, Object> schema = new LinkedHashMap<>();
        schema.put("type", "object");
        schema.put("properties", new LinkedHashMap<String, Object>(properties));
        schema.put("required", List.copyOf(required));
        schema.put("additionalProperties", false);
        return schema;
    }

    public static Map<String, Object> property(String type, String description) {
        Map<String, Object> property = new LinkedHashMap<>();
        property.put("type", type);
        property.put("description", description);
        return property;
    }
}
