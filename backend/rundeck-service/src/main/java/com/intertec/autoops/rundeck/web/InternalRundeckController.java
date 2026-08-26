package com.intertec.autoops.rundeck.web;

import com.intertec.autoops.rundeck.exception.RundeckException;
import com.intertec.autoops.rundeck.service.PlatformRundeck;
import com.intertec.autoops.rundeck.service.JobProvisioner;
import com.intertec.autoops.rundeck.service.JobTranslator;
import com.intertec.autoops.rundeck.service.ProjectProvisioner;
import com.intertec.autoops.rundeck.service.StepRunner;
import com.intertec.autoops.rundeck.web.dto.JobSyncRequest;
import com.intertec.autoops.rundeck.web.dto.ProjectSyncRequest;
import com.intertec.autoops.rundeck.web.dto.StepExecutionRequest;
import com.intertec.autoops.rundeck.web.dto.StepExecutionResult;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.Map;

/**
 * The whole public surface of this service: core-service asks it to run a step.
 *
 * <p><strong>There is no {@code /api/**} controller any more, and that is the
 * point.</strong> The engine is white-labelled — a tenant sees Jobs and
 * Executions with AutoOps branding and has no endpoint, no screen and no
 * database row through which the word Rundeck, its URL or its token could
 * reach them. Anything that existed for a tenant to manage their own Rundeck
 * has been deleted rather than hidden, because a hidden endpoint behind the
 * gateway is still an endpoint.
 *
 * <p>Guarded by {@code X-Internal-Token}, and that guard now protects the
 * execution of every job for every tenant on the platform. The tenant is a
 * FIELD on the request rather than a token claim, so a caller who got past the
 * filter could run a step as anyone — which is why the filter is
 * constant-time and runs before any controller is resolved.
 */
@RestController
@RequestMapping("/internal/rundeck")
public class InternalRundeckController {

    private final StepRunner stepRunner;
    private final PlatformRundeck platform;
    private final ProjectProvisioner provisioner;
    private final JobProvisioner jobs;

    public InternalRundeckController(StepRunner stepRunner, PlatformRundeck platform,
                                     ProjectProvisioner provisioner, JobProvisioner jobs) {
        this.stepRunner = stepRunner;
        this.platform = platform;
        this.provisioner = provisioner;
        this.jobs = jobs;
    }

    /**
     * Execute one step and block until it finishes.
     *
     * <p>Synchronous on purpose: it replaces job-service's
     * {@code POST /internal/execute} exactly, so core-service's run engine —
     * its retries, {@code continueOnError}, cancel-between-steps and the
     * approval gate — is untouched by the swap.
     */
    @PostMapping("/step")
    public StepExecutionResult step(@RequestBody StepExecutionRequest request) {
        if (request.tenantId() == null || request.tenantId().isBlank()) {
            throw RundeckException.badRequest("missing_tenant", "tenantId is required");
        }
        return stepRunner.run(request);
    }

    /**
     * A project was created, renamed or restored in AutoOps — make the engine
     * agree.
     *
     * <p>Provisions the Rundeck project if it is not there yet, which is what
     * makes creation EAGER: the two lists match as soon as a tenant makes a
     * project, rather than only once something has run in it. The existing
     * provision-on-first-step path stays exactly as it was, so this call going
     * nowhere costs nothing at run time.
     *
     * <p>Then writes the display name on. Failing to label a project is not a
     * reason to fail creating one, so {@code syncMetadata} swallows its own
     * errors — but a failure to PROVISION still surfaces, because that one
     * means no step can ever run there.
     */
    @PostMapping("/project")
    public Map<String, Object> syncProject(@RequestBody ProjectSyncRequest request) {
        requireTarget(request.tenantId(), request.projectId());
        String project = provisioner.ensureProject(request.tenantId(), request.projectId());
        provisioner.syncMetadata(request.tenantId(), request.projectId(),
                request.label(), request.description());
        return Map.of("rundeckProject", project, "at", Instant.now().toString());
    }

    /**
     * A project was archived in AutoOps — delete it from the engine.
     *
     * <p>Destroys that project's execution history, by product decision: the
     * engine's project list is to mirror the tenant's ACTIVE projects and
     * nothing else. A later restore comes back through {@code /project} and is
     * provisioned fresh and empty.
     */
    @PostMapping("/project/archive")
    public Map<String, Object> archiveProject(@RequestBody ProjectSyncRequest request) {
        requireTarget(request.tenantId(), request.projectId());
        // Jobs first. Deleting the project removes its jobs on the engine
        // anyway, but the MAPPING rows would survive and go on claiming
        // jobs exist in a project that no longer does.
        jobs.removeAllForProject(request.tenantId(), request.projectId());
        provisioner.archive(request.tenantId(), request.projectId());
        return Map.of("archived", true, "at", Instant.now().toString());
    }

    /**
     * A job was created or edited in AutoOps — put it on the engine.
     *
     * <p>This is what makes an AutoOps job a real Rundeck job: it appears on the
     * engine's JOBS screen, carries its schedule, and can be run by UUID.
     *
     * <p>Not best-effort, unlike the project sync. A job that silently failed to
     * import would look present in AutoOps and be absent everywhere it matters,
     * so the failure is returned and the caller decides.
     */
    @PostMapping("/job")
    public Map<String, Object> syncJob(@RequestBody JobSyncRequest request) {
        requireTarget(request.tenantId(), request.projectId());
        if (request.jobId() == null) {
            throw RundeckException.badRequest("missing_job", "jobId is required");
        }
        String uuid = jobs.sync(new JobTranslator.JobSpec(
                request.tenantId(), request.projectId(), request.jobId(),
                request.name(), request.description(), request.definition(),
                request.schedule(), request.scheduleTimezone(),
                !Boolean.FALSE.equals(request.enabled()),
                Boolean.TRUE.equals(request.requiresApproval())));
        return Map.of("rundeckJobUuid", uuid, "at", Instant.now().toString());
    }

    /** A job was deleted in AutoOps — take it off the engine. */
    @PostMapping("/job/delete")
    public Map<String, Object> deleteJob(@RequestBody JobSyncRequest request) {
        if (request.tenantId() == null || request.tenantId().isBlank()) {
            throw RundeckException.badRequest("missing_tenant", "tenantId is required");
        }
        if (request.jobId() == null) {
            throw RundeckException.badRequest("missing_job", "jobId is required");
        }
        jobs.remove(request.tenantId(), request.jobId());
        return Map.of("deleted", true, "at", Instant.now().toString());
    }

    private static void requireTarget(String tenantId, Long projectId) {
        if (tenantId == null || tenantId.isBlank()) {
            throw RundeckException.badRequest("missing_tenant", "tenantId is required");
        }
        if (projectId == null) {
            throw RundeckException.badRequest("missing_project", "projectId is required");
        }
    }

    /**
     * Readiness of the ENGINE, not of this service.
     *
     * <p>core-service uses it to tell "the platform cannot run jobs" apart from
     * "this one job failed" — a distinction that decides whether an operator
     * pages someone or reads a stack trace.
     */
    @GetMapping("/ping")
    public Map<String, Object> ping() {
        return Map.of(
                "service", "rundeck-service",
                "engineConfigured", platform.isConfigured(),
                "at", Instant.now().toString());
    }
}
