package com.intertec.autoops.plugin.config;

import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.context.event.EventListener;

import java.util.ArrayList;
import java.util.List;

/**
 * Refuses to run in prod on development secrets, mirroring core-service's
 * guard of the same name.
 *
 * <p>Both defaults here are catastrophic in production for different reasons:
 * the dev credential key means every tenant's webhook URLs and SMTP passwords
 * are decryptable by anyone with the source, and the dev internal token means
 * anyone who can reach the service can post fabricated lifecycle events into
 * any tenant's channels.
 */
@Configuration
@Profile("prod")
public class ProdSafetyGuard {

    private final PluginProperties properties;

    public ProdSafetyGuard(PluginProperties properties) {
        this.properties = properties;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void verify() {
        List<String> problems = new ArrayList<>();
        if (PluginProperties.DEV_CREDENTIAL_KEY.equals(properties.getCredentialKey())) {
            problems.add("PLUGIN_CRED_KEY is still the development default — every stored "
                    + "webhook URL, API token and SMTP password would be readable");
        }
        if (PluginProperties.DEV_INTERNAL_TOKEN.equals(properties.getInternalToken())) {
            problems.add("PLUGIN_INTERNAL_TOKEN is still the development default — anyone "
                    + "who can reach /internal could send notifications as any tenant");
        }
        if (!problems.isEmpty()) {
            throw new IllegalStateException("Refusing to start in prod:\n  - "
                    + String.join("\n  - ", problems));
        }
    }
}
