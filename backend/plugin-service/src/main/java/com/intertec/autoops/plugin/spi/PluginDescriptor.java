package com.intertec.autoops.plugin.spi;

import com.intertec.autoops.plugin.exception.PluginException;

import java.util.List;
import java.util.Map;

/**
 * The catalog entry for a plugin: who it is, what it needs, and where the
 * tenant goes to get those values. Everything the install UI shows comes from
 * here.
 */
public record PluginDescriptor(
        String key,
        String displayName,
        Category category,
        String summary,
        /** Where the tenant obtains the credential — shown as "How do I get this?". */
        String setupUrl,
        List<ConfigField> fields) {

    public enum Category {
        CHAT,
        EMAIL,
        TICKETING
    }

    /**
     * Rejects a config that cannot possibly work, before anything is stored.
     * Unknown keys are refused too — a typo'd field name would otherwise be
     * saved, encrypted, and then silently ignored at send time.
     */
    public void validate(Map<String, String> config) {
        for (ConfigField field : fields) {
            String value = config.get(field.name());
            if (field.required() && (value == null || value.isBlank())) {
                throw PluginException.badRequest("missing_config_field",
                        field.label() + " is required for " + displayName);
            }
            if (value != null && !value.isBlank()) {
                validateShape(field, value.trim());
            }
        }
        for (String provided : config.keySet()) {
            if (fields.stream().noneMatch(f -> f.name().equals(provided))) {
                throw PluginException.badRequest("unknown_config_field",
                        "'" + provided + "' is not a setting for " + displayName);
            }
        }
    }

    private void validateShape(ConfigField field, String value) {
        switch (field.type()) {
            case URL -> {
                if (!value.startsWith("https://")) {
                    // http:// would send the credential in the clear, and every
                    // provider here issues https endpoints anyway.
                    throw PluginException.badRequest("invalid_config_field",
                            field.label() + " must be an https:// URL");
                }
            }
            case EMAIL -> {
                if (!value.matches("[^@\\s]+@[^@\\s]+\\.[^@\\s]+")) {
                    throw PluginException.badRequest("invalid_config_field",
                            field.label() + " must be an email address");
                }
            }
            case NUMBER -> {
                try {
                    Integer.parseInt(value);
                } catch (NumberFormatException ex) {
                    throw PluginException.badRequest("invalid_config_field",
                            field.label() + " must be a number");
                }
            }
            default -> {
                // TEXT, SECRET and BOOLEAN carry no shape the platform can check.
            }
        }
    }

    /** Field names whose values must be encrypted and never read back. */
    public List<String> secretFieldNames() {
        return fields.stream().filter(ConfigField::isSecret).map(ConfigField::name).toList();
    }
}
