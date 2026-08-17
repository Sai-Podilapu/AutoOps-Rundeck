package com.intertec.autoops.jobs.execution.ssh;

import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.ProcessSupport;
import com.intertec.autoops.jobs.execution.StepRunner;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/**
 * Runs a command on a remote host over SSH — value format:
 * {@code user@host command args...}. Uses the system ssh client in strict
 * non-interactive mode, so key-based auth must be provisioned (mount keys
 * into the container at /home/autoops/.ssh). Password prompts never hang a
 * run: BatchMode makes them fail fast with a clear error.
 */
@Component
public class SshRunner implements StepRunner {

    private final JobProperties properties;

    public SshRunner(JobProperties properties) {
        this.properties = properties;
    }

    @Override
    public Set<String> types() {
        return Set.of("ssh");
    }

    @Override
    public StepResult run(StepCommand command) throws Exception {
        String value = command.value() == null ? "" : command.value().trim();
        int space = value.indexOf(' ');
        String target = space > 0 ? value.substring(0, space) : value;
        String remote = space > 0 ? value.substring(space + 1).trim() : "";
        if (!target.contains("@") || remote.isEmpty()) {
            return StepResult.failed(
                    "SSH step must be \"user@host command...\" — e.g. deploy@10.0.0.5 systemctl restart app",
                    null, null);
        }
        List<String> ssh = new ArrayList<>(List.of("ssh",
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=10",
                target));
        ssh.add(remote);
        ProcessSupport.ProcessResult result = ProcessSupport.run(
                command.workspace().wrap(ssh),
                command.workspace().environment(), command.workspace().workingDirectory(),
                command.timeout(), properties.getOutputMaxChars(),
                properties.getEnvPassthrough());
        if (result.timedOut()) {
            return StepResult.failed("SSH command timed out after " + command.timeout().toSeconds() + "s",
                    result.output(), null);
        }
        if (result.exitCode() == 255) {
            return StepResult.failed("SSH connection to " + target
                    + " failed (key auth provisioned for the job runner?)", result.output(), 255);
        }
        return result.exitCode() == 0
                ? StepResult.ok(result.output(), result.exitCode())
                : StepResult.failed("Remote command exited with code " + result.exitCode(),
                        result.output(), result.exitCode());
    }
}
