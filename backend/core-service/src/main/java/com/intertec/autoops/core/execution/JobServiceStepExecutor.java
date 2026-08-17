package com.intertec.autoops.core.execution;

import com.intertec.autoops.core.config.CoreProperties;
import com.intertec.autoops.core.domain.CloudPlatform;
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
import java.util.Set;

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

    /** Step types that execute against a tenant cloud integration. */
    private static final Set<CloudPlatform> TERRAFORM_PLATFORMS =
            Set.of(CloudPlatform.AWS, CloudPlatform.AZURE, CloudPlatform.GCP);
    private static final Set<CloudPlatform> KUBERNETES_PLATFORMS =
            Set.of(CloudPlatform.KUBERNETES);
    private static final Set<CloudPlatform> LAMBDA_PLATFORMS = Set.of(CloudPlatform.AWS);
    private static final Set<CloudPlatform> AZURE_FN_PLATFORMS = Set.of(CloudPlatform.AZURE);

    private final RestClient restClient;
    private final CoreProperties properties;
    private final CloudConnectionService cloudConnectionService;

    public JobServiceStepExecutor(CoreProperties properties,
                                  CloudConnectionService cloudConnectionService) {
        this.properties = properties;
        this.cloudConnectionService = cloudConnectionService;
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
            attachCredentials(tenantId, projectId, step, body);
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

    /**
     * terraform steps run with the tenant's AWS/Azure/GCP integration,
     * kubernetes steps with a KUBERNETES (kubeconfig) integration, awslambda
     * with an AWS one, azurefn with an AZURE one — bound by the step's
     * optional {@code connection} name, else the single match. Terraform MAY
     * run credential-less (provider-free configs) and azurefn too (key in the
     * URL or anonymous auth); kubernetes and awslambda cannot do anything
     * without credentials, so those are hard errors.
     */
    private void attachCredentials(String tenantId, Long projectId, RunStep step,
                                   Map<String, Object> body) {
        Set<CloudPlatform> platforms = switch (step.type()) {
            case "terraform" -> TERRAFORM_PLATFORMS;
            case "kubernetes" -> KUBERNETES_PLATFORMS;
            case "awslambda", "lambda" -> LAMBDA_PLATFORMS;
            case "azurefn", "azurefunction" -> AZURE_FN_PLATFORMS;
            default -> null;
        };
        if (platforms == null) {
            return;
        }
        String connectionName = step.raw().path("connection").asText(null);
        Optional<CloudConnectionService.CredentialBundle> bundle =
                cloudConnectionService.resolveForStep(tenantId, projectId, connectionName,
                        platforms);
        if (bundle.isEmpty()) {
            // "available to this project" matters: a matching integration may
            // exist but be dedicated to a different project.
            if ("kubernetes".equals(step.type())) {
                throw CoreException.badRequest("missing_credentials",
                        "Kubernetes steps need a KUBERNETES cloud integration with a "
                                + "kubeconfig available to this project — add or assign one "
                                + "under Cloud Integrations");
            }
            if ("awslambda".equals(step.type()) || "lambda".equals(step.type())) {
                throw CoreException.badRequest("missing_credentials",
                        "AWS Lambda steps need an AWS cloud integration with credentials "
                                + "available to this project — add or assign one under "
                                + "Cloud Integrations");
            }
            return; // provider-free terraform / anonymous azurefn are legitimate
        }
        body.put("credentials", Map.of(
                "platform", bundle.get().platform().name(),
                "connection", bundle.get().name(),
                "data", bundle.get().data()));
    }
}
