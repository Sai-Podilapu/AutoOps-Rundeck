package com.intertec.autoops.rundeck.service;

import com.intertec.autoops.rundeck.client.RundeckApiClient;
import com.intertec.autoops.rundeck.config.RundeckProperties;
import com.intertec.autoops.rundeck.exception.RundeckException;
import org.springframework.stereotype.Component;

/**
 * The single Rundeck AutoOps runs behind the product.
 *
 * <p>Its address and admin token come from the environment, never from a
 * database row — which is what makes the white-label model hold. There is no
 * table a tenant could read them out of, no API that returns them, and no
 * screen that renders them. The console shows Jobs and Executions with AutoOps
 * branding; the engine underneath is an implementation detail the customer is
 * never told about.
 *
 * <p>This class is the only source of a {@link RundeckApiClient.Target} in the
 * execution path. Keeping it a single, tiny component is deliberate: "which
 * Rundeck are we talking to" must have exactly one answer, or the isolation
 * argument built on top of it stops being checkable.
 */
@Component
public class PlatformRundeck {

    private final RundeckProperties.Platform platform;

    public PlatformRundeck(RundeckProperties properties) {
        this.platform = properties.getPlatform();
    }

    /**
     * Credentials for the platform Rundeck.
     *
     * <p>Throws rather than returning a half-configured target when the token
     * is missing. A deployment without one cannot run a single job, and saying
     * so plainly at the first step beats a wall of 401s that read like the
     * customer's problem.
     */
    public RundeckApiClient.Target target() {
        if (platform.getApiToken() == null || platform.getApiToken().isBlank()) {
            throw RundeckException.serviceUnavailable("rundeck_not_configured",
                    "The execution engine is not configured — RUNDECK_API_TOKEN is unset. "
                            + "No jobs can run until it is.");
        }
        return new RundeckApiClient.Target(platform.getUrl(), platform.getApiVersion(),
                platform.getApiToken());
    }

    /** True when this deployment can execute anything at all. */
    public boolean isConfigured() {
        return platform.getApiToken() != null && !platform.getApiToken().isBlank();
    }

    public RundeckProperties.Platform settings() {
        return platform;
    }
}
