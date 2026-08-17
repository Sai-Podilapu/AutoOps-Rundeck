package com.intertec.autoops.core.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

import java.time.Duration;

/**
 * The Dify instance that backs workflow design and execution.
 *
 * <p><b>Why the browser never holds these.</b> Dify's console API is
 * authenticated with a workspace token that can create, edit and DELETE every
 * app in the workspace, and read every model provider credential in it. Handing
 * that to a tenant's browser would give any customer full control of every
 * other customer's workflows. So the key lives here, server-side, and the
 * console talks to {@code /api/dify/**} on this service instead — which is
 * also where the PROVIDER-role check happens.
 *
 * <p>Unconfigured is a legitimate state: {@link #isConfigured()} is false and
 * the bridge answers 503 with a message naming the missing setting, rather
 * than 500-ing on a null base URL or silently pretending the feature works.
 */
@Component
@ConfigurationProperties(prefix = "autoops.dify")
public class DifyProperties {

    /** e.g. https://dify.yourcompany.com — no trailing slash needed. */
    private String baseUrl = "";

    /** Console API token. Never sent to a browser. */
    private String apiKey = "";

    private Duration connectTimeout = Duration.ofSeconds(3);

    /** Generous: publishing an app and DSL export are both slow calls. */
    private Duration readTimeout = Duration.ofSeconds(30);

    /**
     * How long one blocking workflow run may take. Far longer than
     * {@link #readTimeout} on purpose — a run walks LLM nodes and tool calls,
     * so minutes is normal where a console read is milliseconds.
     */
    private Duration runTimeout = Duration.ofMinutes(10);

    /** True once both the URL and the key are set. */
    public boolean isConfigured() {
        return baseUrl != null && !baseUrl.isBlank()
                && apiKey != null && !apiKey.isBlank();
    }

    /** Base URL without a trailing slash, so path concatenation is safe. */
    public String normalizedBaseUrl() {
        String url = baseUrl == null ? "" : baseUrl.trim();
        while (url.endsWith("/")) {
            url = url.substring(0, url.length() - 1);
        }
        return url;
    }

    public String getBaseUrl() {
        return baseUrl;
    }

    public void setBaseUrl(String baseUrl) {
        this.baseUrl = baseUrl;
    }

    public String getApiKey() {
        return apiKey;
    }

    public void setApiKey(String apiKey) {
        this.apiKey = apiKey;
    }

    public Duration getConnectTimeout() {
        return connectTimeout;
    }

    public void setConnectTimeout(Duration connectTimeout) {
        this.connectTimeout = connectTimeout;
    }

    public Duration getReadTimeout() {
        return readTimeout;
    }

    public void setReadTimeout(Duration readTimeout) {
        this.readTimeout = readTimeout;
    }

    public Duration getRunTimeout() {
        return runTimeout;
    }

    public void setRunTimeout(Duration runTimeout) {
        this.runTimeout = runTimeout;
    }
}
