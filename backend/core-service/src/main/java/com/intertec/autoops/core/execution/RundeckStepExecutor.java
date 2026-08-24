package com.intertec.autoops.core.execution;

import com.intertec.autoops.core.config.CoreProperties;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.CloudConnectionService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

/**
 * The executor that REPLACES job-service: every step goes to rundeck-service,
 * which runs it on the platform Rundeck.
 *
 * <p>Selected with {@code autoops.core.execution.mode=rundeck}.
 *
 * <p><strong>Nothing above this class changes.</strong> It implements the same
 * {@link StepExecutor} seam job-service used, synchronously, returning the same
 * {@link StepOutcome} — so the run engine's retries, {@code continueOnError},
 * cancel-between-steps, run history and the approval gate all behave exactly as
 * before. Swapping the runtime was never supposed to be a rewrite of
 * orchestration, and this is where that promise is kept.
 *
 * <p>What IS new is {@code nodeFilter}: a step may now name a slice of a fleet
 * ({@code tags: web+prod}) and fan out across it. Steps that do not carry one
 * run on the engine itself, which is precisely what they did under job-service —
 * so an unmigrated job behaves identically.
 */
@Component
@ConditionalOnProperty(name = "autoops.core.execution.mode", havingValue = "rundeck")
public class RundeckStepExecutor implements StepExecutor {

    private static final Logger log = LoggerFactory.getLogger(RundeckStepExecutor.class);

    private final RestClient restClient;
    private final CoreProperties properties;
    private final StepCredentials credentials;

    public RundeckStepExecutor(CoreProperties properties, StepCredentials credentials) {
        this.properties = properties;
        this.credentials = credentials;
        JdkClientHttpRequestFactory requestFactory = new JdkClientHttpRequestFactory();
        // rundeck-service BLOCKS for the length of the step, so this read
        // timeout has to outlive the step's own budget. Set to the step timeout
        // it would otherwise cut short, plus slack for dispatch and the final
        // log flush. Too tight and every long step fails as "runtime
        // unavailable" while it is in fact still running.
        requestFactory.setReadTimeout(
                properties.getExecution().getStepTimeout().plus(Duration.ofSeconds(60)));
        this.restClient = RestClient.builder()
                .baseUrl(properties.getExecution().getRundeckServiceUrl())
                .requestFactory(requestFactory)
                .build();
        log.info("Step execution mode: rundeck via {}",
                properties.getExecution().getRundeckServiceUrl());
    }

    @Override
    @SuppressWarnings("unchecked")
    public StepOutcome execute(String tenantId, Long projectId, RunStep step) {
        Map<String, Object> body = new HashMap<>();
        body.put("tenantId", tenantId);
        body.put("projectId", projectId);
        body.put("stepIndex", step.index());
        body.put("stepType", step.type());
        body.put("label", step.label());
        body.put("value", step.raw().path("value").asText(null));
        body.put("raw", step.raw());
        body.put("timeoutSeconds", properties.getExecution().getStepTimeout().toSeconds());
        // Optional per-step fan-out. Absent means "run on the engine", which is
        // the job-service behaviour every existing step was written against.
        putIfPresent(body, "nodeFilter", step.raw().path("nodeFilter").asText(null));
        if (step.raw().hasNonNull("nodeThreadcount")) {
            body.put("nodeThreadcount", step.raw().path("nodeThreadcount").asInt());
        }
        if (step.raw().hasNonNull("nodeKeepgoing")) {
            body.put("nodeKeepgoing", step.raw().path("nodeKeepgoing").asBoolean());
        }

        try {
            String connectionName = step.raw().path("connection").asText(null);
            Optional<CloudConnectionService.CredentialBundle> bundle =
                    credentials.resolve(tenantId, projectId, step.type(), connectionName);
            // FLAT, unlike job-service's {platform, connection, data} envelope:
            // the translator maps these keys straight onto the environment
            // variable names each toolchain reads, so there is no envelope to
            // unwrap and no chance of unwrapping it wrongly.
            bundle.ifPresent(b -> body.put("credentials", b.data()));
        } catch (CoreException ex) {
            // Configuration problem (no or ambiguous integration). A failed step
            // with the reason on it beats an exception that fails the whole run.
            return StepOutcome.failed(ex.getMessage(), 0);
        }

        try {
            Map<String, Object> response = restClient.post()
                    .uri("/internal/rundeck/step")
                    .header("X-Internal-Token",
                            properties.getExecution().getRundeckServiceToken())
                    .body(body)
                    .retrieve()
                    .body(Map.class);
            if (response == null) {
                return StepOutcome.failed("Empty response from the execution engine", 0);
            }
            boolean success = Boolean.TRUE.equals(response.get("success"));
            String output = str(response.get("output"));
            String error = str(response.get("error"));
            long durationMs = response.get("durationMs") instanceof Number n ? n.longValue() : 0;
            return success
                    ? StepOutcome.ok(output, durationMs)
                    : StepOutcome.failed(error != null ? error : "step failed", output, durationMs);
        } catch (Exception ex) {
            log.warn("Execution engine call failed for tenant {} step '{}': {}",
                    tenantId, step.label(), ex.getMessage());
            return StepOutcome.failed(
                    "Execution runtime unavailable (" + ex.getMessage() + ") — retry shortly", 0);
        }
    }

    private static void putIfPresent(Map<String, Object> body, String key, String value) {
        if (value != null && !value.isBlank()) {
            body.put(key, value);
        }
    }

    private static String str(Object value) {
        return value == null ? null : value.toString();
    }
}
