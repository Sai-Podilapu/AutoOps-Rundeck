package com.intertec.autoops.jobs.execution.powershell;

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
 * Runs a step's value as a PowerShell script: written to a .ps1 in the step's
 * own workspace, executed with pwsh, then deleted.
 *
 * <p><b>What this does and does not unblock.</b> PowerShell Core runs the
 * cross-platform modules — AWS.Tools, Az, PowerCLI, Microsoft.Graph, SqlServer
 * — so AWS, Azure, VMware, M365 and SQL Server automations work here. It does
 * NOT run the Windows-only ones: {@code Get-ADUser}, the Exchange management
 * shell and most Windows Server cmdlets need an actual Windows host, reached
 * over WinRM. Those are a separate transport, not a missing module.
 *
 * <p><b>-File, not -Command.</b> The script goes to disk and is executed by
 * path. Passing a step's body as {@code -Command} would re-parse it as a
 * command line, so a value containing a quote or a semicolon would be split
 * somewhere the author never intended.
 *
 * <p><b>Non-zero on error.</b> pwsh exits 0 even after a terminating error
 * unless told otherwise, which would report a failed automation as a success.
 * {@code $ErrorActionPreference='Stop'} plus a trap that exits 1 is prepended
 * so a thrown error becomes a failed step. A script that sets its own
 * preference later simply overrides the default, which is the intended
 * precedence.
 */
@Component
public class PowerShellRunner implements StepRunner {

    /**
     * Prepended to every script. Without it, {@code throw} inside a script run
     * by -File still exits 0 and the step is recorded as succeeded.
     */
    private static final String STRICT_PREAMBLE = """
            $ErrorActionPreference = 'Stop'
            trap { Write-Error $_; exit 1 }
            """;

    private final JobProperties properties;

    public PowerShellRunner(JobProperties properties) {
        this.properties = properties;
    }

    @Override
    public Set<String> types() {
        // 'pwsh' is accepted as an alias so a definition written against the
        // binary name still dispatches here.
        return Set.of("powershell", "pwsh");
    }

    @Override
    public StepResult run(StepCommand command) throws Exception {
        if (command.value() == null || command.value().isBlank()) {
            return StepResult.failed(
                    "Step has no script — edit the automation and fill in the PowerShell body",
                    null, null);
        }

        Path script = command.workspace().createFile("autoops-step-", ".ps1");
        try {
            Files.writeString(script, STRICT_PREAMBLE + command.value(), StandardCharsets.UTF_8);
            script.toFile().setExecutable(true, true);
            // The step runs as its own user: the script it executes has to
            // belong to that user, not to the service that wrote it.
            command.workspace().handOver(script);

            // The step's own environment, plus whatever cloud integration was
            // bound to it. AWS.Tools reads AWS_ACCESS_KEY_ID and
            // Connect-AzAccount reads AZURE_CLIENT_ID, so this is all a cloud
            // module needs to authenticate — without it, every one of the
            // cross-platform automations this runner exists to serve would
            // reach an account it has no credentials for.
            Map<String, String> env = new HashMap<>(command.workspace().environment());
            env.putAll(CloudCredentialEnv.forBundle(command.credentials(),
                    command.workspace().workingDirectory()));

            ProcessSupport.ProcessResult result = ProcessSupport.run(
                    command.workspace().wrap(interpreter(script)),
                    env, command.workspace().workingDirectory(),
                    command.timeout(), properties.getOutputMaxChars(),
                    properties.getEnvPassthrough());

            if (result.timedOut()) {
                return StepResult.failed(
                        "PowerShell script timed out after " + command.timeout().toSeconds() + "s",
                        result.output(), null);
            }
            if (result.exitCode() == 127 || isMissingInterpreter(result)) {
                // Distinguished from a script error on purpose: "the automation
                // failed" and "this deployment cannot run PowerShell at all"
                // need completely different actions from whoever reads it.
                return StepResult.failed(
                        "PowerShell is not installed in this deployment, so this automation "
                                + "cannot run here. Install pwsh in the job-service image.",
                        result.output(), result.exitCode());
            }
            return result.exitCode() == 0
                    ? StepResult.ok(result.output(), result.exitCode())
                    : StepResult.failed("PowerShell script exited with code " + result.exitCode(),
                            result.output(), result.exitCode());
        } finally {
            Files.deleteIfExists(script);
        }
    }

    /**
     * -NoProfile so a machine-local profile cannot change how an automation
     * behaves, and -NonInteractive so a prompt fails fast instead of hanging
     * until the step's timeout.
     */
    static List<String> interpreter(Path script) {
        return List.of("pwsh", "-NoProfile", "-NonInteractive", "-NoLogo",
                "-File", script.toAbsolutePath().toString());
    }

    /** A missing binary surfaces differently across shells; match both shapes. */
    private static boolean isMissingInterpreter(ProcessSupport.ProcessResult result) {
        String output = result.output() == null ? "" : result.output().toLowerCase();
        return output.contains("pwsh: not found") || output.contains("no such file or directory")
                && output.contains("pwsh");
    }
}
