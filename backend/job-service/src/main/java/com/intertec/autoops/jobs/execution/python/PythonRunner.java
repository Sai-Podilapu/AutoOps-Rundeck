package com.intertec.autoops.jobs.execution.python;

import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.ProcessSupport;
import com.intertec.autoops.jobs.execution.StepRunner;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Set;

/** Runs the step's value as a Python script (python3 in the container). */
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
            ProcessSupport.ProcessResult result = ProcessSupport.run(
                    command.workspace().wrap(
                            List.of(interpreter, script.toAbsolutePath().toString())),
                    command.workspace().environment(), command.workspace().workingDirectory(),
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
