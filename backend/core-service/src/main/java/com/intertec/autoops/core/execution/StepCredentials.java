package com.intertec.autoops.core.execution;

import com.intertec.autoops.core.domain.CloudPlatform;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.CloudConnectionService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.Optional;
import java.util.Set;

/**
 * Which cloud credential a step runs with.
 *
 * <p>Extracted from {@code JobServiceStepExecutor} when Rundeck became the
 * second executor. The rules below are subtle, were arrived at through
 * production bugs, and are identical whichever runtime performs the step — so
 * they live in one place rather than being copied into the new executor, where
 * the copy would drift.
 */
@Component
public class StepCredentials {

    private static final Logger log = LoggerFactory.getLogger(StepCredentials.class);

    private static final Set<CloudPlatform> TERRAFORM_PLATFORMS =
            Set.of(CloudPlatform.AWS, CloudPlatform.AZURE, CloudPlatform.GCP);
    private static final Set<CloudPlatform> KUBERNETES_PLATFORMS =
            Set.of(CloudPlatform.KUBERNETES);
    private static final Set<CloudPlatform> LAMBDA_PLATFORMS = Set.of(CloudPlatform.AWS);
    private static final Set<CloudPlatform> AZURE_FN_PLATFORMS = Set.of(CloudPlatform.AZURE);

    /**
     * Script steps that talk to a cloud provider through its SDK — boto3 in a
     * pyscript step, Az in a powershell one. These carry the bulk of the
     * automation library, and until they were listed here they ran with no
     * credentials at all.
     */
    private static final Set<CloudPlatform> SCRIPT_PLATFORMS =
            Set.of(CloudPlatform.AWS, CloudPlatform.AZURE, CloudPlatform.GCP);

    private static final Set<String> SCRIPT_STEP_TYPES =
            Set.of("pyscript", "powershell", "pwsh");

    private final CloudConnectionService cloudConnectionService;

    public StepCredentials(CloudConnectionService cloudConnectionService) {
        this.cloudConnectionService = cloudConnectionService;
    }

    /**
     * The credential bundle for a step, or empty when it legitimately runs
     * without one.
     *
     * <p>Throws {@link CoreException} when the step CANNOT work without
     * credentials (kubernetes, awslambda) — the caller turns that into a failed
     * step with a readable message rather than letting it reach the engine.
     */
    public Optional<CloudConnectionService.CredentialBundle> resolve(
            String tenantId, Long projectId, String stepType, String connectionName) {

        Set<CloudPlatform> platforms = switch (stepType) {
            case "terraform" -> TERRAFORM_PLATFORMS;
            case "kubernetes" -> KUBERNETES_PLATFORMS;
            case "awslambda", "lambda" -> LAMBDA_PLATFORMS;
            case "azurefn", "azurefunction" -> AZURE_FN_PLATFORMS;
            case "pyscript", "powershell", "pwsh" -> SCRIPT_PLATFORMS;
            default -> null;
        };
        if (platforms == null) {
            return Optional.empty();
        }

        // Decided from the STEP TYPE, never from the platform set. Terraform and
        // script steps allow the same three platforms, so comparing the sets
        // would quietly give terraform the lenient behaviour meant only for
        // scripts.
        boolean script = SCRIPT_STEP_TYPES.contains(stepType);

        Optional<CloudConnectionService.CredentialBundle> bundle;
        try {
            bundle = cloudConnectionService.resolveForStep(tenantId, projectId, connectionName,
                    platforms);
        } catch (CoreException ex) {
            // A tenant with two cloud integrations in reach gets
            // "ambiguous_connection" when a step names neither. For terraform or
            // a lambda invoke that is right — those steps exist to talk to a
            // cloud account. For a SCRIPT step it is not: most pyscript steps
            // never touch a cloud SDK, and failing them the moment a customer
            // adds a second AWS integration would break automations that had
            // nothing to do with it.
            if (script && "ambiguous_connection".equals(ex.getError())) {
                log.info("Step '{}' has several cloud integrations in reach and names none; "
                        + "running it without credentials. Set \"connection\" on the step if "
                        + "it needs one.", stepType);
                return Optional.empty();
            }
            throw ex;
        }

        if (bundle.isEmpty()) {
            // "available to this project" matters: a matching integration may
            // exist but be dedicated to a different project.
            if ("kubernetes".equals(stepType)) {
                throw CoreException.badRequest("missing_credentials",
                        "Kubernetes steps need a KUBERNETES cloud integration with a "
                                + "kubeconfig available to this project — add or assign one "
                                + "under Cloud Integrations");
            }
            if ("awslambda".equals(stepType) || "lambda".equals(stepType)) {
                throw CoreException.badRequest("missing_credentials",
                        "AWS Lambda steps need an AWS cloud integration with credentials "
                                + "available to this project — add or assign one under "
                                + "Cloud Integrations");
            }
            // provider-free terraform / anonymous azurefn are legitimate
            return Optional.empty();
        }
        return bundle;
    }
}
