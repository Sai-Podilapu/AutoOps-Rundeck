package com.intertec.autoops.jobs.execution.kubernetes;

import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.ArgumentLine;
import com.intertec.autoops.jobs.execution.ProcessSupport;
import com.intertec.autoops.jobs.execution.StepRunner;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Runs kubectl against the tenant's KUBERNETES integration (its kubeconfig,
 * decrypted by core-service, written to a scratch file for the call).
 * Value format — first line is the kubectl arguments (a leading "kubectl "
 * is tolerated), any further lines are a manifest applied via {@code -f}:
 * <pre>
 *   get pods -n production
 *
 *   apply -n staging
 *   apiVersion: apps/v1
 *   kind: Deployment
 *   ...
 * </pre>
 */
@Component
public class KubernetesRunner implements StepRunner {

    private final JobProperties properties;

    public KubernetesRunner(JobProperties properties) {
        this.properties = properties;
    }

    @Override
    public Set<String> types() {
        return Set.of("kubernetes");
    }

    @Override
    public StepResult run(StepCommand command) throws Exception {
        if (command.value() == null || command.value().isBlank()) {
            return StepResult.failed("Kubernetes step has no command — e.g. \"get pods -A\" "
                    + "or \"apply\" followed by a manifest on the next lines", null, null);
        }
        String kubeconfig = command.credentials() != null
                ? command.credentials().path("data").path("kubeconfig").asText("") : "";
        if (kubeconfig.isBlank()) {
            return StepResult.failed("No kubeconfig — connect a KUBERNETES cloud integration "
                    + "with your cluster's kubeconfig first", null, null);
        }

        String[] lines = command.value().split("\r?\n", 2);
        String args = lines[0].trim();
        if (args.toLowerCase().startsWith("kubectl ")) {
            args = args.substring("kubectl ".length()).trim();
        }
        String manifest = lines.length > 1 ? lines[1].trim() : "";
        List<String> arguments = ArgumentLine.tokenize(args);
        if (arguments.isEmpty()) {
            return StepResult.failed("Kubernetes step has no kubectl arguments — e.g. "
                    + "\"get pods -A\"", null, null);
        }

        // Inside the step's own workspace: a kubeconfig in the shared temp
        // directory is readable by every other step in this container.
        Path kubeconfigFile = command.workspace().createFile("autoops-kubeconfig-", ".yaml");
        Path manifestFile = null;
        try {
            Files.writeString(kubeconfigFile, kubeconfig, StandardCharsets.UTF_8);
            kubeconfigFile.toFile().setReadable(false, false);
            kubeconfigFile.toFile().setReadable(true, true);
            command.workspace().handOver(kubeconfigFile);

            List<String> kubectl = new ArrayList<>();
            kubectl.add("kubectl");
            kubectl.addAll(arguments);
            if (!manifest.isEmpty() && !ArgumentLine.hasFileArgument(arguments)) {
                manifestFile = command.workspace().createFile("autoops-manifest-", ".yaml");
                Files.writeString(manifestFile, manifest, StandardCharsets.UTF_8);
                command.workspace().handOver(manifestFile);
                kubectl.add("-f");
                kubectl.add(manifestFile.toAbsolutePath().toString());
            }

            Map<String, String> env = new HashMap<>(command.workspace().environment());
            env.put("KUBECONFIG", kubeconfigFile.toAbsolutePath().toString());
            ProcessSupport.ProcessResult result = ProcessSupport.run(
                    command.workspace().wrap(kubectl), env,
                    command.workspace().workingDirectory(),
                    command.timeout(), properties.getOutputMaxChars(),
                    properties.getEnvPassthrough());
            if (result.timedOut()) {
                return StepResult.failed("kubectl timed out after "
                        + command.timeout().toSeconds() + "s", result.output(), null);
            }
            return result.exitCode() == 0
                    ? StepResult.ok(result.output(), 0)
                    : StepResult.failed("kubectl exited with code " + result.exitCode(),
                            result.output(), result.exitCode());
        } catch (IOException ex) {
            return StepResult.failed("kubectl not available on this runner: " + ex.getMessage(),
                    null, null);
        } finally {
            Files.deleteIfExists(kubeconfigFile);
            if (manifestFile != null) {
                Files.deleteIfExists(manifestFile);
            }
        }
    }
}
