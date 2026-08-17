package com.intertec.autoops.voice.config;

import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProdSafetyGuardTest {

    private static MockEnvironment env(String... profiles) {
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles(profiles);
        return environment;
    }

    @Test
    void devConfigurationIsNeverChecked() {
        VoiceProperties properties = new VoiceProperties();
        properties.getRateLimit().setEnabled(false);
        properties.setApiBaseUrl("http://localhost:9999");

        assertThatCode(() -> new ProdSafetyGuard(env("dev"), properties).verifyProdConfiguration())
                .doesNotThrowAnyException();
    }

    @Test
    void prodRefusesToRunThePublicEndpointUncapped() {
        VoiceProperties properties = new VoiceProperties();
        properties.getRateLimit().setEnabled(false);

        assertThatThrownBy(() -> new ProdSafetyGuard(env("prod"), properties).verifyProdConfiguration())
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("uncapped");
    }

    @Test
    void prodRefusesToSendTheApiKeyOverPlainHttp() {
        VoiceProperties properties = new VoiceProperties();
        properties.setApiBaseUrl("http://api.elevenlabs.io");

        assertThatThrownBy(() -> new ProdSafetyGuard(env("prod"), properties).verifyProdConfiguration())
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("not https");
    }

    @Test
    void prodRefusesToRunAlongsideDev() {
        assertThatThrownBy(() -> new ProdSafetyGuard(env("prod", "dev"), new VoiceProperties())
                .verifyProdConfiguration())
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("'dev' profile is active");
    }

    @Test
    void missingCredentialsAreAWarningNotAStartupFailure() {
        // An un-keyed prod deploy should degrade to "no talk button", not to a
        // platform that will not boot.
        assertThatCode(() -> new ProdSafetyGuard(env("prod"), new VoiceProperties())
                .verifyProdConfiguration())
                .doesNotThrowAnyException();
    }
}
