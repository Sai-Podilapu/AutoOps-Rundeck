package com.intertec.autoops.jobs.config;

import com.intertec.autoops.jobs.sandbox.StepSandbox;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.ApplicationListener;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Component;

import java.util.Arrays;

/**
 * Refuses to start the prod profile on dev defaults. This service runs
 * arbitrary commands — shipping it with the well-known dev token would be
 * an open remote shell.
 */
@Component
public class ProdSafetyGuard implements ApplicationListener<ApplicationReadyEvent> {

    private final Environment environment;
    private final JobProperties properties;
    private final StepSandbox sandbox;

    public ProdSafetyGuard(Environment environment, JobProperties properties,
                           StepSandbox sandbox) {
        this.environment = environment;
        this.properties = properties;
        this.sandbox = sandbox;
    }

    @Override
    public void onApplicationEvent(ApplicationReadyEvent event) {
        boolean prod = Arrays.asList(environment.getActiveProfiles()).contains("prod");
        if (!prod) {
            return;
        }
        if (JobProperties.DEV_TOKEN.equals(properties.getInternalToken())) {
            throw new IllegalStateException(
                    "job-service refuses to start in prod with the default internal token — "
                            + "set JOB_INTERNAL_TOKEN to a strong secret");
        }
        if (!sandbox.active()) {
            // Without per-step users, one tenant's step can read another's
            // decrypted credentials out of the shared scratch area.
            throw new IllegalStateException(
                    "job-service refuses to start in prod without per-step isolation: "
                            + sandbox.inactiveReason());
        }
    }
}
