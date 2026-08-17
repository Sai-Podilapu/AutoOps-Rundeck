package com.intertec.autoops.agent.modelsdk;

import java.util.Map;

/**
 * A tenant's decrypted provider config, keyed exactly as core-service's
 * catalog names its form fields ({@code apiKey}, {@code region},
 * {@code endpoint}, ...).
 *
 * <p>Every vendor package reads its credentials through this one type, so a
 * missing field fails the same way for all six — naming the vendor AND the
 * field — instead of each SDK reporting it differently, or worse, later, as a
 * puzzling 401 from the vendor.
 *
 * <p>Holds decrypted secrets, so it is short-lived by construction: build it,
 * build a client with it, drop it. Never log one, never put one on an entity.
 */
public record ModelCredentials(ModelVendor vendor, Map<String, String> values) {

    public ModelCredentials {
        values = values == null ? Map.of() : Map.copyOf(values);
    }

    public static ModelCredentials of(ModelVendor vendor, Map<String, String> values) {
        return new ModelCredentials(vendor, values);
    }

    /**
     * @throws IllegalArgumentException naming the vendor and the missing field
     */
    public String require(String key) {
        String value = values.get(key);
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(
                    vendor + " credentials are missing \"" + key + "\"");
        }
        return value.trim();
    }

    /** As {@link #require}, minus the trailing slash a pasted URL carries. */
    public String requireUrl(String key) {
        String url = require(key);
        while (url.endsWith("/")) {
            url = url.substring(0, url.length() - 1);
        }
        return url;
    }

    /** For the genuinely optional fields — Ollama's token, Azure's version. */
    public String orElse(String key, String fallback) {
        String value = values.get(key);
        return value == null || value.isBlank() ? fallback : value.trim();
    }

    /** Never let a credential map reach a log line by accident. */
    @Override
    public String toString() {
        return "ModelCredentials[vendor=" + vendor + ", values=<redacted>]";
    }
}
