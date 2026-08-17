package com.intertec.autoops.jobs.service;

import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.StepRunner;
import com.intertec.autoops.jobs.sandbox.SandboxException;
import com.intertec.autoops.jobs.sandbox.StepSandbox;
import com.intertec.autoops.jobs.sandbox.StepWorkspace;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Dispatches a step to the runner for its type, applies the timeout policy,
 * and normalizes the outcome. Step types with no real executor FAIL with a
 * clear message — pretending to run infrastructure would be worse than
 * refusing.
 *
 * <p>{@code job_steps_total{type,outcome}} counts every execution.
 */
@Service
public class StepExecutionService {

    private static final Logger log = LoggerFactory.getLogger(StepExecutionService.class);

    private final Map<String, StepRunner> runnersByType = new HashMap<>();
    private final JobProperties properties;
    private final StepSandbox sandbox;
    /** Nullable: tests have no MeterRegistry; prod wires Prometheus. */
    private final MeterRegistry meterRegistry;

    public StepExecutionService(List<StepRunner> runners, JobProperties properties,
                                StepSandbox sandbox,
                                ObjectProvider<MeterRegistry> meterRegistry) {
        runners.forEach(r -> r.types().forEach(t -> runnersByType.put(t, r)));
        this.properties = properties;
        this.sandbox = sandbox;
        this.meterRegistry = meterRegistry.getIfAvailable();
    }

    public record Execution(boolean success, String output, String error,
                            Integer exitCode, long durationMs, String executor) {
    }

    public Execution execute(StepRunner.StepCommand rawCommand) {
        String type = rawCommand.stepType() == null ? ""
                : rawCommand.stepType().toLowerCase(Locale.ROOT);
        StepRunner runner = runnersByType.get(type);
        Instant start = Instant.now();
        StepRunner.StepResult result;
        String executor = runner != null ? runner.getClass().getSimpleName() : "none";
        if (runner == null) {
            result = StepRunner.StepResult.failed(
                    "No executor for step type '" + type + "' yet. Supported today: command, "
                            + "agent, script, pyscript, ssh, rest, terraform, kubernetes, "
                            + "awslambda, azurefn, test.",
                    null, null);
        } else {
            // One workspace per step: its own directory, its own OS user where
            // the platform supports it, and both gone when the step ends.
            try (StepWorkspace workspace = sandbox.acquire()) {
                StepRunner.StepCommand command = new StepRunner.StepCommand(
                        rawCommand.tenantId(), type, rawCommand.label(), rawCommand.value(),
                        rawCommand.raw(), clampTimeout(rawCommand.timeout()),
                        rawCommand.credentials(), workspace);
                try {
                    result = runner.run(command);
                } catch (Exception ex) {
                    log.error("Step runner {} crashed for tenant {}", executor,
                            rawCommand.tenantId(), ex);
                    result = StepRunner.StepResult.failed(
                            "Executor error: " + ex.getMessage(), null, null);
                }
            } catch (SandboxException ex) {
                log.error("Refused step for tenant {}: {}", rawCommand.tenantId(), ex.getMessage());
                result = StepRunner.StepResult.failed(ex.getMessage(), null, null);
            }
        }
        long durationMs = Duration.between(start, Instant.now()).toMillis();
        count(type, result.success());
        log.info("Tenant {} step '{}' ({}) -> {} in {}ms", rawCommand.tenantId(),
                rawCommand.label(), type, result.success() ? "ok" : "failed", durationMs);
        return new Execution(result.success(), truncate(result.output()), result.error(),
                result.exitCode(), durationMs, executor);
    }

    private Duration clampTimeout(Duration requested) {
        Duration timeout = requested == null || requested.isZero() || requested.isNegative()
                ? properties.getDefaultStepTimeout() : requested;
        return timeout.compareTo(properties.getMaxStepTimeout()) > 0
                ? properties.getMaxStepTimeout() : timeout;
    }

    private String truncate(String output) {
        if (output == null) {
            return null;
        }
        int max = properties.getOutputMaxChars();
        return output.length() <= max ? output : output.substring(0, max) + "\n… output truncated …";
    }

    private void count(String type, boolean success) {
        if (meterRegistry != null) {
            meterRegistry.counter("job_steps_total",
                    "type", type.isEmpty() ? "unknown" : type,
                    "outcome", success ? "ok" : "failed").increment();
        }
    }
}
