package com.intertec.autoops.voice.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/** All voice-agent settings, kebab-case under {@code autoops.voice.*}. */
@ConfigurationProperties("autoops.voice")
public class VoiceProperties {

    /** Placeholder shipped in application.yml so an unconfigured stack still boots. */
    public static final String UNSET = "REPLACE_ME";

    /**
     * ElevenLabs API key. Server-side only: it is the credential that can spend
     * the account's credits, so it must never be sent to a browser — every
     * response this service produces is a short-lived signed URL instead.
     */
    private String apiKey = UNSET;

    /** The Aegis-01 agent created in the ElevenLabs dashboard (agent_…). */
    private String agentId = UNSET;

    /** Display name the landing page shows on the talk button. */
    private String agentName = "Aegis-01";

    /** ElevenLabs REST base; regional deployments override it. */
    private String apiBaseUrl = "https://api.elevenlabs.io";

    /** How long we wait on ElevenLabs before giving the visitor an honest error. */
    private Duration requestTimeout = Duration.ofSeconds(10);

    private final RateLimit rateLimit = new RateLimit();

    /**
     * The landing page is public, so this endpoint is unauthenticated and every
     * call it serves costs conversation credits. These caps are what stops a
     * scripted client from draining the account overnight; they are deliberately
     * generous for a human visitor and tight for a loop.
     */
    public static class RateLimit {

        /** false disables both caps — local development only. */
        private boolean enabled = true;

        /** Sessions one client IP may open per window. */
        private int perIp = 5;

        /** Sessions the whole service may hand out per window, across all IPs. */
        private int global = 120;

        /** Sliding window both caps are measured over. */
        private Duration window = Duration.ofMinutes(10);

        public boolean isEnabled() {
            return enabled;
        }

        public void setEnabled(boolean enabled) {
            this.enabled = enabled;
        }

        public int getPerIp() {
            return perIp;
        }

        public void setPerIp(int perIp) {
            this.perIp = perIp;
        }

        public int getGlobal() {
            return global;
        }

        public void setGlobal(int global) {
            this.global = global;
        }

        public Duration getWindow() {
            return window;
        }

        public void setWindow(Duration window) {
            this.window = window;
        }
    }

    /** True once both the key and the agent id have been supplied. */
    public boolean isConfigured() {
        return isSet(apiKey) && isSet(agentId);
    }

    private static boolean isSet(String value) {
        return value != null && !value.isBlank() && !UNSET.equals(value);
    }

    public String getApiKey() {
        return apiKey;
    }

    public void setApiKey(String apiKey) {
        this.apiKey = apiKey;
    }

    public String getAgentId() {
        return agentId;
    }

    public void setAgentId(String agentId) {
        this.agentId = agentId;
    }

    public String getAgentName() {
        return agentName;
    }

    public void setAgentName(String agentName) {
        this.agentName = agentName;
    }

    public String getApiBaseUrl() {
        return apiBaseUrl;
    }

    public void setApiBaseUrl(String apiBaseUrl) {
        this.apiBaseUrl = apiBaseUrl;
    }

    public Duration getRequestTimeout() {
        return requestTimeout;
    }

    public void setRequestTimeout(Duration requestTimeout) {
        this.requestTimeout = requestTimeout;
    }

    public RateLimit getRateLimit() {
        return rateLimit;
    }
}