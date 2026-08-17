package com.intertec.autoops.jobs.web;

import com.fasterxml.jackson.databind.JsonNode;
import com.intertec.autoops.jobs.execution.StepRunner;
import com.intertec.autoops.jobs.service.StepExecutionService;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.time.Duration;

/**
 * Internal execution API for core-service (guarded by InternalTokenFilter,
 * never routed through the gateway). One call = one step, synchronous — the
 * caller owns run orchestration, retries, and history.
 */
@RestController
public class ExecuteController {

    private final StepExecutionService stepExecutionService;

    public ExecuteController(StepExecutionService stepExecutionService) {
        this.stepExecutionService = stepExecutionService;
    }

    public record ExecuteRequest(String tenantId, String stepType, String label,
                                 String value, JsonNode raw, Long timeoutSeconds,
                                 JsonNode credentials) {
    }

    public record ExecuteResponse(boolean success, String output, String error,
                                  Integer exitCode, long durationMs, String executor) {
    }

    @PostMapping("/internal/execute")
    public ExecuteResponse execute(@RequestBody ExecuteRequest request) {
        StepExecutionService.Execution execution = stepExecutionService.execute(
                new StepRunner.StepCommand(
                        request.tenantId(), request.stepType(), request.label(),
                        request.value(), request.raw(),
                        request.timeoutSeconds() != null
                                ? Duration.ofSeconds(request.timeoutSeconds()) : null,
                        request.credentials()));
        return new ExecuteResponse(execution.success(), execution.output(), execution.error(),
                execution.exitCode(), execution.durationMs(), execution.executor());
    }
}
