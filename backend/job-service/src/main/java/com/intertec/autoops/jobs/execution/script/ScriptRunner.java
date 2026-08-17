package com.intertec.autoops.jobs.execution.script;

import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.ProcessSupport;
import com.intertec.autoops.jobs.execution.StepRunner;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;

/**
 * Runs the step's value as a multi-line shell script: written to a temp file,
 * executed with bash/sh (cmd.exe on a Windows dev box), then deleted.
 */
@Component
public class ScriptRunner implements StepRunner {

    private final JobProperties properties;

    public ScriptRunner(JobProperties properties) {
        this.properties = properties;
    }

    @Override
    public Set<String> types() {
        return Set.of("script");
    }

    @Override
    public StepResult run(StepCommand command) throws Exception {
        if (command.value() == null || command.value().isBlank()) {
            return StepResult.failed("Step has no script — edit the job and fill in the script body", null, null);
        }
        Path script = command.workspace().createFile("autoops-step-",
                ProcessSupport.scriptExtension());
        try {
            Files.writeString(script, command.value(), StandardCharsets.UTF_8);
            script.toFile().setExecutable(true, true);
            // The step runs as its own user: the script it executes has to
            // belong to that user, not to the service that wrote it.
            command.workspace().handOver(script);
            ProcessSupport.ProcessResult result = ProcessSupport.run(
                    command.workspace().wrap(ProcessSupport.scriptCommand(script)),
                    command.workspace().environment(), command.workspace().workingDirectory(),
                    command.timeout(), properties.getOutputMaxChars(),
                    properties.getEnvPassthrough());
            if (result.timedOut()) {
                return StepResult.failed("Script timed out after " + command.timeout().toSeconds() + "s",
                        result.output(), null);
            }
            return result.exitCode() == 0
                    ? StepResult.ok(result.output(), result.exitCode())
                    : StepResult.failed("Script exited with code " + result.exitCode(),
                            result.output(), result.exitCode());
        } finally {
            Files.deleteIfExists(script);
        }
    }
}
