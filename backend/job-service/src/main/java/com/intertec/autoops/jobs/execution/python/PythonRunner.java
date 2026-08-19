package com.intertec.autoops.jobs.execution.python;

import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.CloudCredentialEnv;
import com.intertec.autoops.jobs.execution.ProcessSupport;
import com.intertec.autoops.jobs.execution.StepRunner;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Runs the step's value as a Python script (python3 in the container).
 *
 * <p>The image ships {@code boto3} and {@code requests}, so a pyscript step is
 * the shortest path to a real cloud automation — and, until the credential
 * overlay below existed, it could not reach any cloud account. A step bound to
 * a cloud integration now gets that integration's credentials in its
 * environment, which is exactly where boto3 and the Azure SDKs already look.
 */
@Component
public class PythonRunner implements StepRunner {

    private final JobProperties properties;

    public PythonRunner(JobProperties properties) {
        this.properties = properties;
    }

    @Override
    public Set<String> types() {
        return Set.of("pyscript");
    }

    @Override
    public StepResult run(StepCommand command) throws Exception {
        if (command.value() == null || command.value().isBlank()) {
            return StepResult.failed("Step has no Python code — edit the job and fill in the script", null, null);
        }
        String interpreter = ProcessSupport.isWindows() ? "python" : "python3";
        Path script = command.workspace().createFile("autoops-step-", ".py");
        try {
            Files.writeString(script, command.value(), StandardCharsets.UTF_8);
            command.workspace().handOver(script);

            // The step's own environment, plus whatever cloud integration was
            // bound to it. Empty when none is — a script that needs no account
            // is unaffected.
            Map<String, String> env = new HashMap<>(command.workspace().environment());
            env.putAll(CloudCredentialEnv.forBundle(command.credentials(),
                    command.workspace().workingDirectory()));

            ProcessSupport.ProcessResult result = ProcessSupport.run(
                    command.workspace().wrap(
                            List.of(interpreter, script.toAbsolutePath().toString())),
                    env, command.workspace().workingDirectory(),
                    command.timeout(), properties.getOutputMaxChars(),
                    properties.getEnvPassthrough());
            if (result.timedOut()) {
                return StepResult.failed("Python script timed out after "
                        + command.timeout().toSeconds() + "s", result.output(), null);
            }
            return result.exitCode() == 0
                    ? StepResult.ok(result.output(), result.exitCode())
                    : StepResult.failed("Python exited with code " + result.exitCode(),
                            result.output(), result.exitCode());
        } catch (java.io.IOException ex) {
            return StepResult.failed("Python interpreter not available on this runner: "
                    + ex.getMessage(), null, null);
        } finally {
            Files.deleteIfExists(script);
        }
    }
}
