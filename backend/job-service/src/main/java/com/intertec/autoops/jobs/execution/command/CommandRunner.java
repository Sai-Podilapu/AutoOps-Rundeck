package com.intertec.autoops.jobs.execution.command;

import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.ProcessSupport;
import com.intertec.autoops.jobs.execution.StepRunner;
import org.springframework.stereotype.Component;

import java.util.Set;

/**
 * Runs the step's value as a one-line shell command — the Rundeck "Command"
 * step. {@code agent} (the palette's "Agent Command") executes the same way:
 * a command on the execution agent, i.e. this container.
 */
@Component
public class CommandRunner implements StepRunner {

    private final JobProperties properties;

    public CommandRunner(JobProperties properties) {
        this.properties = properties;
    }

    @Override
    public Set<String> types() {
        return Set.of("command", "agent");
    }

    @Override
    public StepResult run(StepCommand command) throws Exception {
        if (command.value() == null || command.value().isBlank()) {
            return StepResult.failed("Step has no command — edit the job and fill in the command field", null, null);
        }
        ProcessSupport.ProcessResult result = ProcessSupport.run(
                command.workspace().wrap(ProcessSupport.shellCommand(command.value())),
                command.workspace().environment(), command.workspace().workingDirectory(),
                command.timeout(), properties.getOutputMaxChars(),
                properties.getEnvPassthrough());
        if (result.timedOut()) {
            return StepResult.failed("Command timed out after " + command.timeout().toSeconds() + "s",
                    result.output(), null);
        }
        return result.exitCode() == 0
                ? StepResult.ok(result.output(), result.exitCode())
                : StepResult.failed("Command exited with code " + result.exitCode(),
                        result.output(), result.exitCode());
    }
}
