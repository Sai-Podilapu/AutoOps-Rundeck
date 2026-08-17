package com.intertec.autoops.jobs.execution.terraform;

import com.fasterxml.jackson.databind.JsonNode;
import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.ProcessSupport;
import com.intertec.autoops.jobs.execution.StepRunner;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Executes the step's value as a Terraform configuration (main.tf) in a
 * scratch workspace: {@code init} then the step's {@code action}
 * (plan | apply | destroy — default apply, Rundeck semantics: triggering a
 * job DOES the thing). Cloud credentials from the tenant's integration are
 * injected as provider environment variables (AWS_*, ARM_*, GOOGLE_*).
 * Provider-free configs run without credentials. The binary is terraform
 * when present, else OpenTofu (drop-in CLI-compatible; what the container
 * ships).
 */
@Component
public class TerraformRunner implements StepRunner {

    private final JobProperties properties;

    public TerraformRunner(JobProperties properties) {
        this.properties = properties;
    }

    @Override
    public Set<String> types() {
        return Set.of("terraform");
    }

    @Override
    public StepResult run(StepCommand command) throws Exception {
        if (command.value() == null || command.value().isBlank()) {
            return StepResult.failed(
                    "Terraform step has no configuration — put your HCL (main.tf content) "
                            + "in the step field", null, null);
        }
        String action = command.raw() != null
                ? command.raw().path("action").asText("apply").toLowerCase(Locale.ROOT) : "apply";
        if (!Set.of("plan", "apply", "destroy").contains(action)) {
            return StepResult.failed("Unknown terraform action '" + action
                    + "' — use plan, apply, or destroy", null, null);
        }

        // The workspace holds the provider credentials (GCP writes a key file
        // here), so it lives inside the step's private, per-user area.
        Path workDir = command.workspace().createDirectory("autoops-tf-");
        try {
            Files.writeString(workDir.resolve("main.tf"), command.value(), StandardCharsets.UTF_8);
            Map<String, String> env = new HashMap<>(command.workspace().environment());
            env.putAll(credentialEnv(command.credentials(), workDir));
            // terraform writes state, plugins and lock files as the step user.
            command.workspace().handOver(workDir);
            String binary = binary();

            StringBuilder log = new StringBuilder("== " + binary + " init ==\n");
            ProcessSupport.ProcessResult init = ProcessSupport.run(
                    command.workspace().wrap(List.of(binary, "init", "-input=false", "-no-color")),
                    env, workDir, command.timeout(), properties.getOutputMaxChars(),
                    properties.getEnvPassthrough());
            log.append(init.output());
            if (init.timedOut() || init.exitCode() != 0) {
                return StepResult.failed(init.timedOut() ? "terraform init timed out"
                        : "terraform init failed (exit " + init.exitCode() + ")",
                        log.toString(), init.exitCode());
            }

            List<String> actionCommand = switch (action) {
                case "plan" -> List.of(binary, "plan", "-input=false", "-no-color");
                case "destroy" -> List.of(binary, "destroy", "-auto-approve", "-input=false", "-no-color");
                default -> List.of(binary, "apply", "-auto-approve", "-input=false", "-no-color");
            };
            log.append("\n== ").append(binary).append(' ').append(action).append(" ==\n");
            ProcessSupport.ProcessResult run = ProcessSupport.run(
                    command.workspace().wrap(actionCommand),
                    env, workDir, command.timeout(), properties.getOutputMaxChars(),
                    properties.getEnvPassthrough());
            log.append(run.output());
            if (run.timedOut()) {
                return StepResult.failed("terraform " + action + " timed out after "
                        + command.timeout().toSeconds() + "s", log.toString(), null);
            }
            return run.exitCode() == 0
                    ? StepResult.ok(log.toString(), 0)
                    : StepResult.failed("terraform " + action + " failed (exit "
                            + run.exitCode() + ")", log.toString(), run.exitCode());
        } finally {
            deleteRecursively(workDir);
        }
    }

    /** terraform if installed, else the OpenTofu the container ships. */
    private String binary() {
        for (String candidate : List.of("terraform", "tofu")) {
            try {
                ProcessSupport.run(List.of(candidate, "version"),
                        java.time.Duration.ofSeconds(10), 200);
                return candidate;
            } catch (Exception ignored) {
                // try next
            }
        }
        return "terraform"; // let the real run produce the not-found error
    }

    /** Provider env vars from the integration's credential bundle. */
    public static Map<String, String> credentialEnv(JsonNode credentials, Path workDir)
            throws IOException {
        Map<String, String> env = new HashMap<>();
        if (credentials == null || credentials.isMissingNode() || credentials.isNull()) {
            return env;
        }
        String platform = credentials.path("platform").asText("");
        JsonNode data = credentials.path("data");
        switch (platform) {
            case "AWS" -> {
                put(env, "AWS_ACCESS_KEY_ID", first(data, "accessId", "accessKey", "accessKeyId"));
                put(env, "AWS_SECRET_ACCESS_KEY", first(data, "secret", "secretKey", "secretAccessKey"));
                put(env, "AWS_DEFAULT_REGION", first(data, "region"));
                put(env, "AWS_REGION", first(data, "region"));
            }
            case "AZURE" -> {
                put(env, "ARM_CLIENT_ID", first(data, "clientId"));
                put(env, "ARM_CLIENT_SECRET", first(data, "clientSecret"));
                put(env, "ARM_TENANT_ID", first(data, "tenantId"));
                put(env, "ARM_SUBSCRIPTION_ID", first(data, "subscriptionId"));
            }
            case "GCP" -> {
                String serviceAccount = first(data, "serviceAccount", "serviceAccountJson");
                if (serviceAccount != null) {
                    Path saFile = workDir.resolve("gcp-sa.json");
                    Files.writeString(saFile, serviceAccount, StandardCharsets.UTF_8);
                    env.put("GOOGLE_APPLICATION_CREDENTIALS", saFile.toAbsolutePath().toString());
                    env.put("GOOGLE_CREDENTIALS", serviceAccount);
                }
                put(env, "GOOGLE_PROJECT", first(data, "projectId"));
            }
            default -> {
                // Unknown platform: no env — the config decides what it needs.
            }
        }
        return env;
    }

    private static String first(JsonNode data, String... keys) {
        for (String key : keys) {
            JsonNode node = data.path(key);
            if (node.isTextual() && !node.asText().isBlank()) {
                return node.asText();
            }
        }
        return null;
    }

    private static void put(Map<String, String> env, String key, String value) {
        if (value != null) {
            env.put(key, value);
        }
    }

    private static void deleteRecursively(Path root) {
        try (var paths = Files.walk(root)) {
            paths.sorted(Comparator.reverseOrder()).forEach(p -> {
                try {
                    Files.deleteIfExists(p);
                } catch (IOException ignored) {
                    // scratch dir — best effort
                }
            });
        } catch (IOException ignored) {
            // best effort
        }
    }
}
