package com.intertec.autoops.jobs.web;

import com.fasterxml.jackson.databind.JsonNode;
import com.intertec.autoops.jobs.execution.StepRunner;
import com.intertec.autoops.jobs.service.StepExecutionService;
import org.springframework.web.bind.annotation.PostMapping;
import java.util.Set;
import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
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

    /**
     * What this deployment can execute. Read by core-service's readiness check
     * so a customer is told up front that an automation cannot run here,
     * instead of discovering it as a failed step. Asking the service rather
     * than hard-coding the list is the whole point: the answer has to change
     * on the day a runner is added.
     */
    @GetMapping("/internal/runners")
    public Map<String, Object> runners() {
        Set<String> types = stepExecutionService.supportedTypes();
        return Map.of("types", types, "count", types.size());
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
