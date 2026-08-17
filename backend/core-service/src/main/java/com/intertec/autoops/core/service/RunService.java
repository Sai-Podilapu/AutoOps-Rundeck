package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.client.SubscriptionInfoClient;
import com.intertec.autoops.core.client.WorkflowClient;
import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.domain.Run;
import com.intertec.autoops.core.domain.RunStatus;
import com.intertec.autoops.core.domain.RunTargetType;
import com.intertec.autoops.core.domain.RunTrigger;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.execution.ExecutionEngine;
import com.intertec.autoops.core.repo.JobRepository;
import com.intertec.autoops.core.repo.ProjectRepository;
import com.intertec.autoops.core.repo.RunRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.core.task.TaskExecutor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.time.Duration;
import java.time.Instant;
import java.util.EnumSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Triggers, lists, and cancels runs. MANUAL triggers are gated mutations;
 * SCHEDULE triggers carry no user token so they skip the entitlement gate
 * (accepted trade-off, documented in the README). History reads are bounded
 * by the plan's {@code history_days} — a read-time bound, never a gate, and
 * never fail-closed.
 */
@Service
public class RunService {

    private static final Logger log = LoggerFactory.getLogger(RunService.class);

    /** Success rate / duration stats are computed over finished runs only. */
    private static final Set<RunStatus> FINISHED = EnumSet.of(RunStatus.SUCCEEDED, RunStatus.FAILED);

    private final RunRepository runRepository;
    private final JobRepository jobRepository;
    private final WorkflowClient workflowClient;
    private final ProjectRepository projectRepository;
    private final SubscriptionGate gate;
    private final SubscriptionInfoClient subscriptionInfoClient;
    private final ExecutionEngine executionEngine;
    private final TaskExecutor executionTaskExecutor;
    private final ObjectMapper objectMapper;
    private final DifyWorkflowService difyWorkflows;
    private final NativeInputValidator nativeInputs;
    /** Nullable in slice tests that don't import it; QUEUED then goes unannounced. */
    private final LifecycleNotifier lifecycleNotifier;

    public RunService(RunRepository runRepository,
                      JobRepository jobRepository,
                      WorkflowClient workflowClient,
                      ProjectRepository projectRepository,
                      SubscriptionGate gate,
                      SubscriptionInfoClient subscriptionInfoClient,
                      ExecutionEngine executionEngine,
                      @Qualifier("executionTaskExecutor") TaskExecutor executionTaskExecutor,
                      ObjectMapper objectMapper,
                      DifyWorkflowService difyWorkflows,
                      NativeInputValidator nativeInputs,
                      ObjectProvider<LifecycleNotifier> lifecycleNotifier) {
        this.runRepository = runRepository;
        this.jobRepository = jobRepository;
        this.workflowClient = workflowClient;
        this.projectRepository = projectRepository;
        this.gate = gate;
        this.subscriptionInfoClient = subscriptionInfoClient;
        this.executionEngine = executionEngine;
        this.executionTaskExecutor = executionTaskExecutor;
        this.objectMapper = objectMapper;
        this.difyWorkflows = difyWorkflows;
        this.nativeInputs = nativeInputs;
        this.lifecycleNotifier = lifecycleNotifier.getIfAvailable();
    }

    // ------ triggers ------

    @Transactional
    public Run runJob(String tenantId, String actor, String accessToken, Long jobId) {
        Job job = jobRepository.findByIdAndTenantId(jobId, tenantId)
                .orElseThrow(() -> CoreException.notFound("job_not_found", "No such job"));
        gate.requireActive(accessToken);
        return queue(tenantId, actor, RunTrigger.MANUAL, RunTargetType.JOB,
                job.getId(), job.getName(), job.getProject().getId(), job.getDefinition());
    }

    @Transactional
    public Run runWorkflow(String tenantId, String actor, String accessToken, Long workflowId) {
        return runWorkflow(tenantId, actor, accessToken, workflowId, null);
    }

    /**
     * @param inputs values for a Dify-backed workflow's published input form.
     *               Validated against that form here — this is the authoritative
     *               check, whatever any caller validated earlier — and ignored
     *               for a plain {@code nodes[]} workflow, which has no form to
     *               validate against.
     */
    @Transactional
    public Run runWorkflow(String tenantId, String actor, String accessToken, Long workflowId,
                           Map<String, Object> inputs) {
        // The definition comes from workflow-service now; the run — history,
        // snapshot, execution — stays here.
        WorkflowClient.WorkflowView workflow = workflowClient.require(tenantId, workflowId);
        gate.requireActive(accessToken);
        return queue(tenantId, actor, RunTrigger.MANUAL, RunTargetType.WORKFLOW,
                workflow.id(), workflow.name(), workflow.projectId(), workflow.definition(),
                validatedInputs(workflow.definition(), inputs));
    }

    /**
     * The published input form for a workflow this tenant holds, or an empty
     * list when it is a plain {@code nodes[]} canvas with nothing to fill in.
     *
     * <p>Reads the definition server-side and returns only the field list, so
     * the customer's browser learns what to ask for without ever receiving the
     * provider's design.
     *
     * <p>Deliberately NOT transactional: both calls it makes are HTTP — one to
     * workflow-service, one to Dify — and wrapping them would pin a pooled DB
     * connection for the length of two network round trips while touching no
     * table at all.
     */
    public List<DifyWorkflowService.InputField> inputFormFor(String tenantId, Long workflowId) {
        WorkflowClient.WorkflowView workflow = workflowClient.require(tenantId, workflowId);
        String slug = difyWorkflows.slugIn(workflow.definition());
        return slug == null ? List.of() : difyWorkflows.inputsFor(slug);
    }

    /**
     * Cleaned inputs as JSON, or null when this workflow declares no form.
     * Null and {@code "{}"} are deliberately different on the run row: null
     * means "nothing was ever asked for", {@code {}} means "the form was shown
     * and every field was optional and left blank".
     */
    private String validatedInputs(String definition, Map<String, Object> inputs) {
        String slug = difyWorkflows.slugIn(definition);
        Map<String, Object> clean;
        if (slug == null) {
            // Native workflow: its own inputs[] is the contract. Until this
            // existed the answers were dropped here and the run started with
            // nothing, so a form could be filled in and silently ignored.
            clean = nativeInputs.validate(definition, inputs);
            if (clean == null) {
                return null;
            }
        } else {
            clean = difyWorkflows.validate(slug, inputs);
        }
        try {
            return objectMapper.writeValueAsString(clean);
        } catch (Exception ex) {
            throw CoreException.badRequest("invalid_inputs",
                    "Those input values could not be recorded");
        }
    }

    /** Scheduler entry point: no user token, so no entitlement gate (trade-off). */
    @Transactional
    public Run runScheduled(Job job) {
        return queue(job.getTenantId(), "scheduler", RunTrigger.SCHEDULE, RunTargetType.JOB,
                job.getId(), job.getName(), job.getProject().getId(), job.getDefinition());
    }

    /** Inbound-webhook entry points: token-authenticated; WebhookService gates. */
    @Transactional
    public Run runFromWebhook(Job job, String webhookName) {
        return queue(job.getTenantId(), "webhook:" + webhookName, RunTrigger.WEBHOOK,
                RunTargetType.JOB, job.getId(), job.getName(),
                job.getProject().getId(), job.getDefinition());
    }

    @Transactional
    public Run runFromWebhook(WorkflowClient.WorkflowView workflow, String webhookName) {
        return queue(workflow.tenantId(), "webhook:" + webhookName, RunTrigger.WEBHOOK,
                RunTargetType.WORKFLOW, workflow.id(), workflow.name(),
                workflow.projectId(), workflow.definition());
    }

    /**
     * Agent entry points: an agent invoking a target from its own allow-list.
     *
     * <p>No entitlement gate here, and deliberately so — there is no user
     * token on an agent's call. The gate ran once already, in agent-service,
     * when the run that is now dispatching this tool was created. Re-gating on
     * a token we do not have would mean either inventing one or failing every
     * agent tool call, and neither is a subscription check.
     *
     * <p>{@code actor} carries the agent, not a person: {@code agent:Patch
     * Operator#12}. An operator reading run history has to be able to tell an
     * agent's run from a human's without inferring it.
     */
    @Transactional
    public Run runFromAgent(Job job, String actor) {
        return queue(job.getTenantId(), actor, RunTrigger.AGENT, RunTargetType.JOB,
                job.getId(), job.getName(), job.getProject().getId(), job.getDefinition());
    }

    /**
     * @param inputs the agent's values for a Dify-backed workflow's input
     *               form. Re-validated here, as on every other path into
     *               {@code queue}: this is the authoritative check, and an
     *               agent's arguments are no more trustworthy than a browser's.
     */
    @Transactional
    public Run runFromAgent(WorkflowClient.WorkflowView workflow, String actor,
                            Map<String, Object> inputs) {
        return queue(workflow.tenantId(), actor, RunTrigger.AGENT, RunTargetType.WORKFLOW,
                workflow.id(), workflow.name(), workflow.projectId(), workflow.definition(),
                validatedInputs(workflow.definition(), inputs));
    }

    /** Every trigger but a manual workflow run supplies no inputs. */
    private Run queue(String tenantId, String actor, RunTrigger trigger, RunTargetType targetType,
                      Long targetId, String targetName, Long projectId, String definition) {
        return queue(tenantId, actor, trigger, targetType, targetId, targetName, projectId,
                definition, null);
    }

    private Run queue(String tenantId, String actor, RunTrigger trigger, RunTargetType targetType,
                      Long targetId, String targetName, Long projectId, String definition,
                      String inputsJson) {
        Run run = new Run();
        run.setTenantId(tenantId);
        run.setProjectId(projectId);
        run.setTargetType(targetType);
        run.setTargetId(targetId);
        run.setTargetName(targetName);
        run.setDefinition(definition);
        run.setInputs(inputsJson);
        run.setTrigger(trigger);
        run.setTriggeredBy(actor);
        run.setStepTotal(countItems(definition, targetType));
        Run saved = runRepository.save(run);
        submitAfterCommit(saved.getId());
        log.info("Tenant {} queued run {} ({} {}, {})", tenantId, saved.getId(),
                targetType, targetId, trigger);
        return saved;
    }

    /**
     * The engine must only see the run AFTER its row is committed.
     *
     * <p>The QUEUED notification rides the same commit hook: announcing a run
     * that a rollback then erased would be reporting something that never
     * happened.
     */
    private void submitAfterCommit(Long runId) {
        Runnable submit = () -> {
            if (lifecycleNotifier != null) {
                runRepository.findById(runId).ifPresent(lifecycleNotifier::runQueued);
            }
            executionTaskExecutor.execute(() -> executionEngine.execute(runId));
        };
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override
                public void afterCommit() {
                    submit.run();
                }
            });
        } else {
            submit.run();
        }
    }

    // ------ reads (retention-bounded, never gated) ------

    @Transactional(readOnly = true)
    public List<Run> list(String tenantId, String accessToken, Long projectId) {
        return list(tenantId, accessToken, projectId, null, null);
    }

    /**
     * A project's runs, or ONE target's when {@code targetType}/{@code targetId}
     * are given — what a job's "History" opens.
     *
     * <p>Filtering here rather than in the caller is the point: both paths cap
     * at the newest 200, so a busy project's noisiest job could otherwise push
     * a quiet job's runs out of the page the client was filtering.
     *
     * <p>The two parameters travel together; one without the other would
     * silently mean "job 7 or workflow 7", which are different runs.
     */
    @Transactional(readOnly = true)
    public List<Run> list(String tenantId, String accessToken, Long projectId,
                          RunTargetType targetType, Long targetId) {
        projectRepository.findByIdAndTenantId(projectId, tenantId)
                .orElseThrow(() -> CoreException.notFound("project_not_found", "No such project"));
        if ((targetType == null) != (targetId == null)) {
            throw CoreException.badRequest("incomplete_target_filter",
                    "targetType and targetId must be given together");
        }
        Instant cutoff = retentionCutoff(tenantId, accessToken);
        if (targetType == null) {
            return runRepository
                    .findTop200ByTenantIdAndProjectIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
                            tenantId, projectId, cutoff);
        }
        return runRepository
                .findTop200ByTenantIdAndProjectIdAndTargetTypeAndTargetIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
                        tenantId, projectId, targetType, targetId, cutoff);
    }

    @Transactional(readOnly = true)
    public Run get(String tenantId, String accessToken, Long id) {
        Run run = runRepository.findByIdAndTenantId(id, tenantId)
                .orElseThrow(() -> CoreException.notFound("run_not_found", "No such run"));
        if (run.getCreatedAt().isBefore(retentionCutoff(tenantId, accessToken))) {
            // Outside the plan's history window — same as not existing.
            throw CoreException.notFound("run_not_found", "No such run");
        }
        return run;
    }

    private Instant retentionCutoff(String tenantId, String accessToken) {
        Integer days = subscriptionInfoClient.historyDays(tenantId, accessToken);
        return days == null ? Instant.EPOCH : Instant.now().minus(Duration.ofDays(days));
    }

    // ------ cancel ------

    @Transactional
    public Run cancel(String tenantId, String accessToken, Long id) {
        gate.requireActive(accessToken);
        Run run = runRepository.findByIdAndTenantId(id, tenantId)
                .orElseThrow(() -> CoreException.notFound("run_not_found", "No such run"));
        if (run.getStatus().isTerminal()) {
            throw CoreException.conflict("run_finished", "This run has already finished");
        }
        run.setCancelRequested(true);
        return runRepository.save(run);
    }

    // ------ stats for workflow/job responses ------

    public record RunStats(long total, Integer successRate, Instant lastRunAt, Long avgDurationMs) {

        static RunStats from(RunRepository.RunStatsRow row) {
            Integer rate = row.getTotal() > 0
                    ? (int) Math.round(100.0 * row.getSucceeded() / row.getTotal()) : null;
            Long avg = row.getAvgDurationMs() != null ? Math.round(row.getAvgDurationMs()) : null;
            return new RunStats(row.getTotal(), rate, row.getLastRunAt(), avg);
        }
    }

    @Transactional(readOnly = true)
    public Map<Long, RunStats> statsForProject(String tenantId, RunTargetType targetType, Long projectId) {
        return runRepository.statsByProject(tenantId, targetType, projectId, FINISHED, RunStatus.SUCCEEDED)
                .stream()
                .collect(Collectors.toMap(RunRepository.RunStatsRow::getTargetId, RunStats::from));
    }

    @Transactional(readOnly = true)
    public Optional<RunStats> statsForTarget(String tenantId, RunTargetType targetType, Long targetId) {
        return runRepository.statsByTarget(tenantId, targetType, targetId, FINISHED, RunStatus.SUCCEEDED)
                .map(RunStats::from);
    }

    // ------------------------------------------------------------------

    /** Progress denominator; the engine re-parses the snapshot before executing. */
    private int countItems(String definition, RunTargetType targetType) {
        if (definition == null || definition.isBlank()) {
            return 0;
        }
        try {
            return objectMapper.readTree(definition)
                    .path(targetType == RunTargetType.JOB ? "steps" : "nodes").size();
        } catch (Exception ex) {
            return 0; // definitions were validated at save time; stay lenient here
        }
    }
}