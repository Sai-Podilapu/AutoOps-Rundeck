package com.intertec.autoops.voice.config;

import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Refuses to start with an unsafe production configuration. This service hands
 * anonymous visitors the ability to spend ElevenLabs credits, so in prod the
 * rate limiter must be on — an unconfigured key is merely useless, a disabled
 * limiter is expensive.
 */
@Component
public class ProdSafetyGuard {

    private static final Logger log = LoggerFactory.getLogger(ProdSafetyGuard.class);

    private final Environment environment;
    private final VoiceProperties properties;

    public ProdSafetyGuard(Environment environment, VoiceProperties properties) {
        this.environment = environment;
        this.properties = properties;
    }

    @PostConstruct
    public void verifyProdConfiguration() {
        List<String> profiles = Arrays.asList(environment.getActiveProfiles());
        if (!profiles.contains("prod")) {
            return;
        }

        List<String> problems = new ArrayList<>();
        if (profiles.contains("dev")) {
            problems.add("the 'dev' profile is active alongside prod");
        }
        if (!properties.getRateLimit().isEnabled()) {
            problems.add("VOICE_RATE_LIMIT is disabled — the public session endpoint would be uncapped");
        }
        if (!properties.getApiBaseUrl().startsWith("https://")) {
            problems.add("VOICE_API_BASE_URL is not https (" + properties.getApiBaseUrl() + ")");
        }

        if (!problems.isEmpty()) {
            throw new IllegalStateException(
                    "Refusing to start with unsafe prod configuration: " + String.join("; ", problems));
        }
        // Not fatal: the landing page hides the talk button when this is false,
        // so an un-keyed prod deploy degrades quietly instead of breaking.
        if (!properties.isConfigured()) {
            log.warn("ELEVENLABS_API_KEY/ELEVENLABS_AGENT_ID not set — the voice agent will report itself disabled");
        }
        log.info("Prod safety checks passed");
    }
}
