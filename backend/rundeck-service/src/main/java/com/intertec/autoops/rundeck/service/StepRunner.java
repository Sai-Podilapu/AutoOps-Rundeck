package com.intertec.autoops.rundeck.service;

import com.intertec.autoops.rundeck.client.RundeckApiClient;
import com.intertec.autoops.rundeck.config.RundeckProperties;
import com.intertec.autoops.rundeck.domain.RundeckDispatch;
import com.intertec.autoops.rundeck.exception.RundeckException;
import com.intertec.autoops.rundeck.repo.RundeckDispatchRepository;
import com.intertec.autoops.rundeck.web.dto.RundeckViews.ExecutionView;
import com.intertec.autoops.rundeck.web.dto.RundeckViews.LogEntry;
import com.intertec.autoops.rundeck.web.dto.RundeckViews.LogView;
import com.intertec.autoops.rundeck.web.dto.StepExecutionRequest;
import com.intertec.autoops.rundeck.web.dto.StepExecutionResult;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Runs ONE AutoOps step on the platform Rundeck and waits for it.
 *
 * <p><strong>Why one step at a time rather than importing the whole job.</strong>
 * Rundeck could run an entire multi-step workflow, and that would look tidier
 * in its own UI. It would also move orchestration out of AutoOps — and
 * orchestration is where the approval gate lives, along with per-step retries,
 * {@code continueOnError} and cancel-between-steps. Those are the product.
 * Rundeck is the hands; AutoOps stays the brain, which is exactly what
 * core-service's existing {@code StepExecutor} seam already assumed.
 *
 * <p>Synchronous by design. core-service's run engine calls a step and expects
 * an outcome, the same as it did with job-service, so this blocks on a poll
 * loop and returns when Rundeck is done. The bound on that wait is the step
 * timeout — and a step that hits it is ABORTED upstream, never abandoned.
 */
@Service
public class StepRunner {

    private static final Logger log = LoggerFactory.getLogger(StepRunner.class);

    /** Rundeck execution states that mean "no longer running". */
    private static final Set<String> TERMINAL =
            Set.of("succeeded", "failed", "aborted", "timedout", "failed-with-retry");

    /** Cap on relayed log text, mirroring job-service's 16 KB output cap. */
    private static final int MAX_OUTPUT_CHARS = 16_000;

    private final PlatformRundeck platform;
    private final ProjectProvisioner provisioner;
    private final StepTranslator translator;
    private final RundeckApiClient apiClient;
    private final RundeckMapper mapper;
    private final RundeckDispatchRepository dispatches;
    private final RundeckProperties.Platform settings;
    private final MeterRegistry meterRegistry;

    public StepRunner(PlatformRundeck platform,
                      ProjectProvisioner provisioner,
                      StepTranslator translator,
                      RundeckApiClient apiClient,
                      RundeckMapper mapper,
                      RundeckDispatchRepository dispatches,
                      RundeckProperties properties,
                      ObjectProvider<MeterRegistry> meterRegistry) {
        this.platform = platform;
        this.provisioner = provisioner;
        this.translator = translator;
        this.apiClient = apiClient;
        this.mapper = mapper;
        this.dispatches = dispatches;
        this.settings = properties.getPlatform();
        this.meterRegistry = meterRegistry.getIfAvailable();
    }

    public StepExecutionResult run(StepExecutionRequest request) {
        long started = System.nanoTime();
        String project = provisioner.ensureProject(request.tenantId(), request.projectId());
        RundeckApiClient.Target target = platform.target();

        StepTranslator.Script script = translator.translate(request);

        RundeckDispatch receipt = receipt(request, project);
        Long executionId = null;
        try {
            var dispatch = apiClient.runScript(target, project, script.body(),
                    script.interpreter(), null, script.fileExtension(),
                    request.nodeFilter(), request.nodeThreadcount(),
                    request.nodeKeepgoing(), null);

            ExecutionView execution = mapper.execution(dispatch);
            executionId = execution.id();
            if (executionId == null) {
                throw RundeckException.upstream("rundeck_no_execution",
                        "The engine accepted the step but returned no execution id");
            }
            receipt.setExecutionId(executionId);
            receipt.setStatus("RUNNING");
            dispatches.save(receipt);

            return await(target, project, executionId, request, receipt, started);
        } catch (RundeckException ex) {
            receipt.setStatus("FAILED");
            receipt.setError(truncate(ex.getMessage(), 500));
            receipt.setExecutionId(executionId);
            receipt.setUpdatedAt(Instant.now());
            dispatches.save(receipt);
            count(request.stepType(), "error");
            // Returned, not rethrown: core-service's engine expects an OUTCOME
            // for a step. A thrown exception there fails the whole run with a
            // stack trace instead of a failed step with a readable reason.
            return StepExecutionResult.failed(ex.getMessage(), elapsedMs(started));
        }
    }

    /**
     * Poll until the execution reaches a terminal state, the step timeout
     * expires, or the thread is interrupted.
     */
    private StepExecutionResult await(RundeckApiClient.Target target, String project,
                                      long executionId, StepExecutionRequest request,
                                      RundeckDispatch receipt, long started) {
        Duration budget = request.timeoutSeconds() != null && request.timeoutSeconds() > 0
                ? Duration.ofSeconds(request.timeoutSeconds())
                : settings.getStepTimeout();
        // The configured ceiling is a ceiling: a caller asking for longer than
        // the platform allows does not get to hold an executor slot forever.
        if (budget.compareTo(settings.getStepTimeout()) > 0) {
            budget = settings.getStepTimeout();
        }
        Instant deadline = Instant.now().plus(budget);

        List<LogEntry> collected = new ArrayList<>();
        String offset = null;
        ExecutionView execution = null;

        while (true) {
            if (Instant.now().isAfter(deadline)) {
                // ABORT rather than walk away. Abandoning it would leave a
                // production change running with nothing watching it — the
                // exact failure job-service's process-tree kill existed to
                // prevent.
                abortQuietly(target, executionId);
                receipt.setStatus("TIMED_OUT");
                receipt.setError("Step exceeded " + budget.toSeconds() + "s and was aborted");
                receipt.setUpdatedAt(Instant.now());
                dispatches.save(receipt);
                count(request.stepType(), "timeout");
                return new StepExecutionResult(false, render(collected),
                        "Step timed out after " + budget.toSeconds() + "s and was aborted",
                        1, elapsedMs(started), executionId, project, List.of(), List.of());
            }

            LogView window = mapper.log(
                    apiClient.executionOutput(target, executionId, offset, null));
            if (!window.entries().isEmpty()) {
                collected.addAll(window.entries());
            }
            if (window.offset() != null && !window.offset().isBlank()) {
                offset = window.offset();
            }

            execution = mapper.execution(apiClient.execution(target, executionId));
            String status = execution.status() == null
                    ? "" : execution.status().toLowerCase(Locale.ROOT);

            // Both conditions, not just status: the log can still be flushing
            // after the execution reports done, and returning early truncates
            // the last lines — which are the ones that say why it failed.
            if (TERMINAL.contains(status) && window.execCompleted()) {
                break;
            }

            try {
                Thread.sleep(settings.getPollInterval().toMillis());
            } catch (InterruptedException ex) {
                Thread.currentThread().interrupt();
                abortQuietly(target, executionId);
                receipt.setStatus("ABORTED");
                receipt.setUpdatedAt(Instant.now());
                dispatches.save(receipt);
                return new StepExecutionResult(false, render(collected),
                        "Step was cancelled", 1, elapsedMs(started), executionId, project,
                        List.of(), List.of());
            }
        }

        String status = execution.status() == null
                ? "" : execution.status().toLowerCase(Locale.ROOT);
        boolean success = "succeeded".equals(status);

        receipt.setStatus(status.toUpperCase(Locale.ROOT));
        receipt.setUpdatedAt(Instant.now());
        if (!success) {
            receipt.setError(truncate("Rundeck execution " + executionId + " " + status, 500));
        }
        dispatches.save(receipt);
        count(request.stepType(), success ? "ok" : "failed");

        return new StepExecutionResult(
                success,
                render(collected),
                success ? null : failureMessage(status, execution),
                success ? 0 : 1,
                elapsedMs(started),
                executionId,
                project,
                execution.failedNodes(),
                execution.succeededNodes());
    }

    /**
     * A failure message an operator can act on.
     *
     * <p>Naming the failed nodes matters here in a way it never did under
     * job-service: a step now runs across a fleet, so "failed" without saying
     * WHERE is the difference between a one-line fix and an afternoon.
     */
    private String failureMessage(String status, ExecutionView execution) {
        StringBuilder message = new StringBuilder("Step ").append(status);
        if (execution.failedNodes() != null && !execution.failedNodes().isEmpty()) {
            message.append(" on ").append(execution.failedNodes().size())
                    .append(execution.failedNodes().size() == 1 ? " node: " : " nodes: ")
                    .append(String.join(", ", execution.failedNodes()));
        }
        return message.toString();
    }

    /** Best-effort: a failed abort must not replace the real error. */
    private void abortQuietly(RundeckApiClient.Target target, long executionId) {
        try {
            apiClient.abort(target, executionId);
        } catch (Exception ex) {
            log.warn("Could not abort Rundeck execution {}: {}", executionId, ex.getMessage());
        }
    }

    /**
     * The log as core-service will append it to the run.
     *
     * <p>The node name is prefixed only when the step actually fanned out;
     * prefixing a single-target step would change how every existing run log
     * reads for no gain.
     */
    private String render(List<LogEntry> entries) {
        boolean multiNode = entries.stream()
                .map(LogEntry::node)
                .filter(n -> n != null && !n.isBlank())
                .distinct()
                .count() > 1;
        StringBuilder out = new StringBuilder();
        for (LogEntry entry : entries) {
            if (multiNode && entry.node() != null && !entry.node().isBlank()) {
                out.append('[').append(entry.node()).append("] ");
            }
            out.append(entry.log() == null ? "" : entry.log()).append('\n');
            if (out.length() > MAX_OUTPUT_CHARS) {
                out.setLength(MAX_OUTPUT_CHARS);
                out.append("\n… output truncated at ").append(MAX_OUTPUT_CHARS)
                        .append(" characters");
                break;
            }
        }
        return out.toString();
    }

    private RundeckDispatch receipt(StepExecutionRequest request, String project) {
        RundeckDispatch receipt = new RundeckDispatch();
        receipt.setTenantId(request.tenantId());
        receipt.setRunId(request.runId());
        receipt.setStepIndex(request.stepIndex());
        receipt.setStepType(request.stepType());
        receipt.setRundeckProject(project);
        receipt.setJobName(request.label());
        receipt.setNodeFilter(request.nodeFilter());
        receipt.setTriggeredBy("run-engine");
        receipt.setStatus("SUBMITTED");
        receipt.setCreatedAt(Instant.now());
        receipt.setUpdatedAt(Instant.now());
        // Deliberately NOT recording the step's value or the credential bundle.
        // The step body is already snapshotted on the AutoOps run; copying it
        // here would duplicate it, and the bundle must never be persisted.
        return receipt;
    }

    private void count(String stepType, String outcome) {
        if (meterRegistry != null) {
            meterRegistry.counter("rundeck_steps_total",
                    "type", stepType == null ? "unknown" : stepType,
                    "outcome", outcome).increment();
        }
    }

    private static long elapsedMs(long startedNanos) {
        return (System.nanoTime() - startedNanos) / 1_000_000L;
    }

    private static String truncate(String value, int max) {
        if (value == null) {
            return null;
        }
        return value.length() > max ? value.substring(0, max - 3) + "..." : value;
    }
}
