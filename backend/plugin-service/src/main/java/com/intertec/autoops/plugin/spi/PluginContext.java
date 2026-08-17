package com.intertec.autoops.plugin.spi;

import com.intertec.autoops.plugin.exception.PluginException;

import java.util.Map;

/**
 * One tenant's decrypted settings for one installed plugin, handed to the
 * plugin for the duration of a single send.
 *
 * <p>Built per attempt and never cached: holding decrypted webhook URLs and
 * SMTP passwords in a long-lived map is how a heap dump becomes a credential
 * leak. {@code config} is already unmodifiable when it arrives.
 */
public record PluginContext(
        String tenantId,
        Long installationId,
        String displayName,
        Map<String, String> config) {

    /** A required value. Absent means the row was written before a field was added. */
    public String require(String key) {
        String value = config.get(key);
        if (value == null || value.isBlank()) {
            throw PluginException.badRequest("missing_config_field",
                    "'" + key + "' is not set on this integration — re-save it");
        }
        return value.trim();
    }

    public String optional(String key, String fallback) {
        String value = config.get(key);
        return value == null || value.isBlank() ? fallback : value.trim();
    }

    public int optionalInt(String key, int fallback) {
        String value = config.get(key);
        if (value == null || value.isBlank()) {
            return fallback;
        }
        try {
            return Integer.parseInt(value.trim());
        } catch (NumberFormatException ex) {
            return fallback;
        }
    }

    public boolean optionalBoolean(String key, boolean fallback) {
        String value = config.get(key);
        return value == null || value.isBlank() ? fallback : Boolean.parseBoolean(value.trim());
    }
}
