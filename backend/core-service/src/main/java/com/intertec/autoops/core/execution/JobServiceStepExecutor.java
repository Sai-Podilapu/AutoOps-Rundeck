package com.intertec.autoops.core.execution;

import com.intertec.autoops.core.config.CoreProperties;
import com.intertec.autoops.core.exception.CoreException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.time.Duration;
import java.util.HashMap;
import java.util.Map;

/**
 * The REAL executor: hands each step to job-service, which runs it
 * (shell command, script, python, ssh, REST call, ...) and returns the
 * captured output. Selected with {@code autoops.core.execution.mode=remote};
 * an unreachable job-service fails the step with a clear error — a run must
 * never hang or silently "succeed" when the runtime is down.
 */
@Component
@ConditionalOnProperty(name = "autoops.core.execution.mode", havingValue = "remote")
public class JobServiceStepExecutor implements StepExecutor {

    private static final Logger log = LoggerFactory.getLogger(JobServiceStepExecutor.class);

    private final RestClient restClient;
    private final CoreProperties properties;
    private final StepCredentials credentials;

    public JobServiceStepExecutor(CoreProperties properties, StepCredentials credentials) {
        this.properties = properties;
        this.credentials = credentials;
        JdkClientHttpRequestFactory requestFactory = new JdkClientHttpRequestFactory();
        // The HTTP read must outlive the step's own timeout budget.
        requestFactory.setReadTimeout(
                properties.getExecution().getStepTimeout().plus(Duration.ofSeconds(15)));
        this.restClient = RestClient.builder()
                .baseUrl(properties.getExecution().getJobServiceUrl())
                .requestFactory(requestFactory)
                .build();
        log.info("Step execution mode: remote via {}",
                properties.getExecution().getJobServiceUrl());
    }

    @Override
    @SuppressWarnings("unchecked")
    public StepOutcome execute(String tenantId, Long projectId, RunStep step) {
        Map<String, Object> body = new HashMap<>();
        body.put("tenantId", tenantId);
        body.put("stepType", step.type());
        body.put("label", step.label());
        body.put("value", step.raw().path("value").asText(null));
        body.put("raw", step.raw());
        body.put("timeoutSeconds", properties.getExecution().getStepTimeout().toSeconds());
        try {
            // Shared with RundeckStepExecutor so the two runtimes cannot drift
            // on which step type gets which credential.
            String connectionName = step.raw().path("connection").asText(null);
            credentials.resolve(tenantId, projectId, step.type(), connectionName)
                    .ifPresent(b -> body.put("credentials", Map.of(
                            "platform", b.platform().name(),
                            "connection", b.name(),
                            "data", b.data())));
        } catch (CoreException ex) {
            // Config problem (no/ambiguous integration) — fail the step clearly.
            return StepOutcome.failed(ex.getMessage(), 0);
        }
        try {
            Map<String, Object> response = restClient.post()
                    .uri("/internal/execute")
                    .header("X-Internal-Token", properties.getExecution().getJobServiceToken())
                    .body(body)
                    .retrieve()
                    .body(Map.class);
            if (response == null) {
                return StepOutcome.failed("Empty response from job-service", 0);
            }
            boolean success = Boolean.TRUE.equals(response.get("success"));
            String output = response.get("output") != null ? response.get("output").toString() : null;
            String error = response.get("error") != null ? response.get("error").toString() : null;
            long durationMs = response.get("durationMs") instanceof Number n ? n.longValue() : 0;
            return success
                    ? StepOutcome.ok(output, durationMs)
                    : StepOutcome.failed(error != null ? error : "step failed", output, durationMs);
        } catch (Exception ex) {
            log.warn("job-service call failed for tenant {} step '{}': {}",
                    tenantId, step.label(), ex.getMessage());
            return StepOutcome.failed(
                    "Execution runtime unavailable (" + ex.getMessage() + ") — retry shortly", 0);
        }
    }

}
