package com.intertec.autoops.rundeck.service;

import com.intertec.autoops.rundeck.client.RundeckApiClient;
import com.intertec.autoops.rundeck.config.RundeckProperties;
import com.intertec.autoops.rundeck.domain.RundeckJob;
import com.intertec.autoops.rundeck.exception.RundeckException;
import com.intertec.autoops.rundeck.repo.RundeckJobRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.Map;

/**
 * Keeps an AutoOps job and its counterpart on the engine in step.
 *
 * <p>This is what puts jobs on Rundeck's own JOBS screen. Before it, a job
 * existed only in {@code autoops_core.jobs} and the engine saw nothing but a
 * stream of anonymous ad-hoc scripts at run time.
 *
 * <p><strong>Scheduling is deliberately NOT handed over yet.</strong> Imported
 * jobs carry their schedule so the engine can display it, but
 * {@code scheduleEnabled} stays false while {@code job-scheduling-enabled} is
 * false — which it is by default. core-service's {@code JobScheduler} still
 * fires every job; if the engine fired them too, every scheduled run would
 * happen twice, and the symptom (duplicate executions at exactly the cron time)
 * looks like a retry bug rather than two owners.
 */
@Service
public class JobProvisioner {

    private static final Logger log = LoggerFactory.getLogger(JobProvisioner.class);

    private final RundeckJobRepository repository;
    private final ProjectProvisioner projects;
    private final JobTranslator translator;
    private final PlatformRundeck platform;
    private final RundeckApiClient apiClient;
    private final RundeckProperties.Platform settings;

    public JobProvisioner(RundeckJobRepository repository,
                          ProjectProvisioner projects,
                          JobTranslator translator,
                          PlatformRundeck platform,
                          RundeckApiClient apiClient,
                          RundeckProperties properties) {
        this.repository = repository;
        this.projects = projects;
        this.translator = translator;
        this.platform = platform;
        this.apiClient = apiClient;
        this.settings = properties.getPlatform();
    }

    /**
     * Create or update this job on the engine.
     *
     * <p>Idempotent: the UUID is derived, and the import uses
     * {@code dupeOption=update}, so calling this on every save edits one job
     * rather than accumulating duplicates.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public String sync(JobTranslator.JobSpec spec) {
        // The job's project must exist on the engine before a job can be
        // imported into it. Eager project provisioning usually means it already
        // does; this covers the job created before that ever ran.
        String project = projects.ensureProject(spec.tenantId(), spec.projectId());

        RundeckJob mapping = repository
                .findByTenantIdAndAutoopsJobId(spec.tenantId(), spec.jobId())
                .orElseGet(() -> create(spec, project));

        boolean engineOwnsSchedule = settings.isJobSchedulingEnabled();
        // Force the engine's scheduler off while core-service still owns the
        // cron. Done here rather than in the translator so the translator stays
        // a pure function of the job, and the double-execution guard lives in
        // one place with the flag that controls it.
        JobTranslator.JobSpec effective = engineOwnsSchedule
                ? spec
                : withSchedulingSuppressed(spec);

        try {
            Map<String, Object> result = apiClient.importJob(
                    platform.target(), project, translator.toRundeckJob(effective));
            failIfRejected(result, spec);

            mapping.setRundeckProject(project);
            mapping.setImported(true);
            mapping.setLastError(null);
            mapping.setScheduleOwnedByEngine(engineOwnsSchedule && spec.cron() != null
                    && !spec.cron().isBlank() && spec.enabled() && !spec.requiresApproval());
        } catch (RundeckException ex) {
            mapping.setImported(false);
            mapping.setLastError(truncate(ex.getMessage()));
            mapping.setUpdatedAt(Instant.now());
            repository.save(mapping);
            log.warn("Could not import job {} (tenant {}) onto the engine: {}",
                    spec.jobId(), spec.tenantId(), ex.getMessage());
            throw ex;
        }
        mapping.setUpdatedAt(Instant.now());
        repository.save(mapping);
        log.info("Imported job {} (tenant {}) as Rundeck job {} in {}",
                spec.jobId(), spec.tenantId(), mapping.getRundeckJobUuid(), project);
        return mapping.getRundeckJobUuid();
    }

    /** Remove one job from the engine and forget the mapping. */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void remove(String tenantId, Long jobId) {
        repository.findByTenantIdAndAutoopsJobId(tenantId, jobId).ifPresent(this::removeMapping);
    }

    /**
     * Remove every job belonging to a project.
     *
     * <p>Called when a project is archived. Rundeck deletes a project's jobs
     * along with the project itself, so the engine-side calls here are usually
     * no-ops — the point is clearing the MAPPING rows, which would otherwise
     * survive and claim jobs exist on an engine that no longer has the project.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void removeAllForProject(String tenantId, Long projectId) {
        List<RundeckJob> mappings = repository.findByTenantIdAndProjectId(tenantId, projectId);
        for (RundeckJob mapping : mappings) {
            removeMapping(mapping);
        }
    }

    private void removeMapping(RundeckJob mapping) {
        if (mapping.isImported()) {
            apiClient.deleteJob(platform.target(), mapping.getRundeckJobUuid());
        }
        repository.delete(mapping);
        log.info("Removed Rundeck job {} (AutoOps job {}, tenant {})",
                mapping.getRundeckJobUuid(), mapping.getAutoopsJobId(), mapping.getTenantId());
    }

    /**
     * Rundeck answers <b>200 with a {@code failed} array</b> when it rejects a
     * job — the status code alone would report success. Without this, a job
     * that never reached the engine would be recorded as imported.
     */
    @SuppressWarnings("unchecked")
    private void failIfRejected(Map<String, Object> result, JobTranslator.JobSpec spec) {
        Object failed = result == null ? null : result.get("failed");
        if (!(failed instanceof List<?> list) || list.isEmpty()) {
            return;
        }
        String detail = "";
        Object first = list.get(0);
        if (first instanceof Map<?, ?> entry) {
            Object error = ((Map<String, Object>) entry).get("error");
            detail = error == null ? "" : " — " + error;
        }
        throw RundeckException.badRequest("job_import_rejected",
                "The engine rejected job \"" + spec.name() + "\"" + detail);
    }

    private JobTranslator.JobSpec withSchedulingSuppressed(JobTranslator.JobSpec spec) {
        // requiresApproval=true is what the translator reads to switch the
        // engine's scheduler off, so reusing it here needs no second flag.
        return new JobTranslator.JobSpec(spec.tenantId(), spec.projectId(), spec.jobId(),
                spec.name(), spec.description(), spec.definitionJson(), spec.cron(),
                spec.timezone(), spec.enabled(), true);
    }

    private RundeckJob create(JobTranslator.JobSpec spec, String project) {
        RundeckJob mapping = new RundeckJob();
        mapping.setTenantId(spec.tenantId());
        mapping.setProjectId(spec.projectId());
        mapping.setAutoopsJobId(spec.jobId());
        mapping.setRundeckProject(project);
        mapping.setRundeckJobUuid(translator.uuidFor(spec.tenantId(), spec.jobId()));
        try {
            return repository.save(mapping);
        } catch (DataIntegrityViolationException ex) {
            // Two saves of the same job racing. The unique key decides; the
            // loser reads the winner's row rather than failing the save.
            return repository.findByTenantIdAndAutoopsJobId(spec.tenantId(), spec.jobId())
                    .orElseThrow(() -> ex);
        }
    }

    private static String truncate(String value) {
        if (value == null) {
            return null;
        }
        return value.length() > 500 ? value.substring(0, 497) + "..." : value;
    }
}
