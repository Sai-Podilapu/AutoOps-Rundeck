package com.intertec.autoops.voice.config;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class VoicePropertiesTest {

    @Test
    void theShippedPlaceholdersDoNotCountAsConfigured() {
        // application.yml defaults to REPLACE_ME so the stack boots un-keyed;
        // treating that as configured would make the page offer a dead button.
        assertThat(new VoiceProperties().isConfigured()).isFalse();
    }

    @Test
    void halfCredentialsAreNotConfigured() {
        VoiceProperties keyOnly = new VoiceProperties();
        keyOnly.setApiKey("sk_real");
        assertThat(keyOnly.isConfigured()).isFalse();

        VoiceProperties agentOnly = new VoiceProperties();
        agentOnly.setAgentId("agent_real");
        assertThat(agentOnly.isConfigured()).isFalse();
    }

    @Test
    void blankAndNullValuesAreNotConfigured() {
        VoiceProperties properties = new VoiceProperties();
        properties.setApiKey("   ");
        properties.setAgentId(null);
        assertThat(properties.isConfigured()).isFalse();
    }

    @Test
    void bothCredentialsPresentIsConfigured() {
        VoiceProperties properties = new VoiceProperties();
        properties.setApiKey("sk_real");
        properties.setAgentId("agent_real");
        assertThat(properties.isConfigured()).isTrue();
    }
}
