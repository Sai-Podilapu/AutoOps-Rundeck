package com.intertec.autoops.agent.modelsdk;

import java.util.Locale;

/**
 * The AI vendors an agent can be pointed at, and which SDK talks to each.
 *
 * <p>This MIRRORS {@code ModelProvider.Kind} in core-service, which owns the
 * credential catalog and is the only service that can decrypt a tenant's key.
 * The two are deliberately separate types rather than a shared module: core
 * knows what a credential looks like, this service knows how to make a call
 * with one, and neither needs the other's concerns on its classpath. The names
 * must match, because core sends the kind across as a string —
 * {@link #fromCode(String)} is where that contract is enforced.
 *
 * <p>Five vendors speak the OpenAI wire format, so they share its SDK with a
 * different base URL. That is a property of the vendor, not a shortcut: their
 * own documentation tells you to point an OpenAI client at their host.
 *
 * <p>Each {@link Sdk} has a sibling package holding the client it builds:
 * {@code openai}, {@code claude} (this enum's {@link #ANTHROPIC}),
 * {@code google}, {@code azure}, {@code bedrock}, {@code huawei}.
 */
public enum ModelVendor {

    OPENAI(Sdk.OPENAI, null),
    ANTHROPIC(Sdk.ANTHROPIC, null),
    GOOGLE(Sdk.GOOGLE, null),
    AZURE_OPENAI(Sdk.AZURE_OPENAI, null),
    BEDROCK(Sdk.BEDROCK, null),
    HUAWEI(Sdk.HUAWEI, null),

    MISTRAL(Sdk.OPENAI, "https://api.mistral.ai/v1"),
    GROQ(Sdk.OPENAI, "https://api.groq.com/openai/v1"),
    DEEPSEEK(Sdk.OPENAI, "https://api.deepseek.com/v1"),
    XAI(Sdk.OPENAI, "https://api.x.ai/v1"),
    /** Self-hosted: the base URL is the tenant's own, so there is none here. */
    OLLAMA(Sdk.OPENAI, null);

    /** Which vendor library backs a kind. */
    public enum Sdk {
        OPENAI, ANTHROPIC, GOOGLE, AZURE_OPENAI, BEDROCK, HUAWEI
    }

    private final Sdk sdk;
    private final String baseUrl;

    ModelVendor(Sdk sdk, String baseUrl) {
        this.sdk = sdk;
        this.baseUrl = baseUrl;
    }

    public Sdk sdk() {
        return sdk;
    }

    /**
     * The fixed host for an OpenAI-compatible vendor, or null when the SDK
     * already knows it (OpenAI) or the tenant supplies it (Ollama, Azure).
     */
    public String baseUrl() {
        return baseUrl;
    }

    /** Null-safe, case-insensitive; null when core sends a kind we cannot serve. */
    public static ModelVendor fromCode(String code) {
        if (code == null || code.isBlank()) {
            return null;
        }
        try {
            return valueOf(code.trim().toUpperCase(Locale.ROOT).replace("-", "_"));
        } catch (IllegalArgumentException ex) {
            return null;
        }
    }
}
