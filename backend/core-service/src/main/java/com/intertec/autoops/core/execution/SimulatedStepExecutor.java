package com.intertec.autoops.core.execution;

import com.intertec.autoops.core.config.CoreProperties;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

import java.util.concurrent.ThreadLocalRandom;

/**
 * Placeholder executor (mode {@code simulated}, the default outside the
 * compose stack): "runs" a step by sleeping a bounded random duration and
 * succeeding. Deterministic failure hook for demos/tests: a step whose JSON
 * carries {@code "simulate":"fail"} (or whose type is {@code fail}) fails
 * with a scripted error. Real execution is {@link JobServiceStepExecutor}.
 */
@Component
@ConditionalOnProperty(name = "autoops.core.execution.mode", havingValue = "simulated",
        matchIfMissing = true)
public class SimulatedStepExecutor implements StepExecutor {

    private final CoreProperties properties;

    public SimulatedStepExecutor(CoreProperties properties) {
        this.properties = properties;
    }

    @Override
    public StepOutcome execute(String tenantId, Long projectId, RunStep step) {
        long min = Math.max(0, properties.getExecution().getSimulatedStepMinDelay().toMillis());
        long max = Math.max(min, properties.getExecution().getSimulatedStepMaxDelay().toMillis());
        long duration = max > min ? ThreadLocalRandom.current().nextLong(min, max + 1) : min;
        try {
            if (duration > 0) {
                Thread.sleep(duration);
            }
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            return StepOutcome.failed("Execution interrupted", duration);
        }
        String simulate = step.raw().path("simulate").asText("");
        boolean fail = "fail".equalsIgnoreCase(simulate) || "fail".equalsIgnoreCase(step.type())
                // "flaky" fails the first attempt only — exercises retry logic.
                || ("flaky".equalsIgnoreCase(simulate) && step.attempt() == 0);
        if (fail) {
            return StepOutcome.failed("Step '" + step.label() + "' failed (simulated)", duration);
        }
        return StepOutcome.ok("completed", duration);
    }
}