package com.intertec.autoops.rundeck.web;

import com.intertec.autoops.rundeck.exception.RundeckException;
import com.intertec.autoops.rundeck.service.PlatformRundeck;
import com.intertec.autoops.rundeck.service.StepRunner;
import com.intertec.autoops.rundeck.web.dto.StepExecutionRequest;
import com.intertec.autoops.rundeck.web.dto.StepExecutionResult;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.Map;

/**
 * The whole public surface of this service: core-service asks it to run a step.
 *
 * <p><strong>There is no {@code /api/**} controller any more, and that is the
 * point.</strong> The engine is white-labelled — a tenant sees Jobs and
 * Executions with AutoOps branding and has no endpoint, no screen and no
 * database row through which the word Rundeck, its URL or its token could
 * reach them. Anything that existed for a tenant to manage their own Rundeck
 * has been deleted rather than hidden, because a hidden endpoint behind the
 * gateway is still an endpoint.
 *
 * <p>Guarded by {@code X-Internal-Token}, and that guard now protects the
 * execution of every job for every tenant on the platform. The tenant is a
 * FIELD on the request rather than a token claim, so a caller who got past the
 * filter could run a step as anyone — which is why the filter is
 * constant-time and runs before any controller is resolved.
 */
@RestController
@RequestMapping("/internal/rundeck")
public class InternalRundeckController {

    private final StepRunner stepRunner;
    private final PlatformRundeck platform;

    public InternalRundeckController(StepRunner stepRunner, PlatformRundeck platform) {
        this.stepRunner = stepRunner;
        this.platform = platform;
    }

    /**
     * Execute one step and block until it finishes.
     *
     * <p>Synchronous on purpose: it replaces job-service's
     * {@code POST /internal/execute} exactly, so core-service's run engine —
     * its retries, {@code continueOnError}, cancel-between-steps and the
     * approval gate — is untouched by the swap.
     */
    @PostMapping("/step")
    public StepExecutionResult step(@RequestBody StepExecutionRequest request) {
        if (request.tenantId() == null || request.tenantId().isBlank()) {
            throw RundeckException.badRequest("missing_tenant", "tenantId is required");
        }
        return stepRunner.run(request);
    }

    /**
     * Readiness of the ENGINE, not of this service.
     *
     * <p>core-service uses it to tell "the platform cannot run jobs" apart from
     * "this one job failed" — a distinction that decides whether an operator
     * pages someone or reads a stack trace.
     */
    @GetMapping("/ping")
    public Map<String, Object> ping() {
        return Map.of(
                "service", "rundeck-service",
                "engineConfigured", platform.isConfigured(),
                "at", Instant.now().toString());
    }
}
