package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.domain.Project;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.JobRepository;
import com.intertec.autoops.core.repo.ProjectRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * Job definitions inside a project. MAX_JOBS gates creation (counted over ALL
 * of the tenant's jobs — deleting frees a slot); step count is parsed
 * SERVER-SIDE from the steps JSON. Steps themselves are not plan-limited.
 * Reads are never gated.
 */
@Service
public class JobService {

    private static final Logger log = LoggerFactory.getLogger(JobService.class);

    private final JobRepository jobRepository;
    private final ProjectRepository projectRepository;
    private final SubscriptionGate gate;
    private final ObjectMapper objectMapper;

    public JobService(JobRepository jobRepository,
                      ProjectRepository projectRepository,
                      SubscriptionGate gate,
                      ObjectMapper objectMapper) {
        this.jobRepository = jobRepository;
        this.projectRepository = projectRepository;
        this.gate = gate;
        this.objectMapper = objectMapper;
    }

    @Transactional(readOnly = true)
    public List<Job> list(String tenantId, Long projectId) {
        requireProject(tenantId, projectId);
        return jobRepository.findByProjectIdAndTenantIdOrderByCreatedAtDesc(projectId, tenantId);
    }

    @Transactional(readOnly = true)
    public Job get(String tenantId, Long id) {
        return jobRepository.findByIdAndTenantId(id, tenantId)
                .orElseThrow(() -> CoreException.notFound("job_not_found", "No such job"));
    }

    @Transactional
    public Job create(String tenantId, String actor, String accessToken, Long projectId,
                      String name, String jobGroup, String description, String definition,
                      String schedule) {
        return create(tenantId, actor, accessToken, projectId, name, jobGroup, description,
                definition, schedule, null);
    }

    @Transactional
    public Job create(String tenantId, String actor, String accessToken, Long projectId,
                      String name, String jobGroup, String description, String definition,
                      String schedule, Boolean requiresApproval) {
        return create(tenantId, actor, accessToken, projectId, name, jobGroup, description,
                definition, schedule, null, requiresApproval);
    }

    @Transactional
    public Job create(String tenantId, String actor, String accessToken, Long projectId,
                      String name, String jobGroup, String description, String definition,
                      String schedule, String scheduleTimezone, Boolean requiresApproval) {
        Project project = requireProject(tenantId, projectId);
        if (jobRepository.existsByProjectIdAndName(projectId, name)) {
            throw CoreException.conflict("job_exists",
                    "A job with this name already exists in the project");
        }
        long count = jobRepository.countByTenantId(tenantId);
        gate.requireQuota(accessToken, "MAX_JOBS", count, "jobs");

        Job job = new Job();
        job.setTenantId(tenantId);
        job.setProject(project);
        job.setName(name);
        job.setJobGroup(jobGroup);
        job.setDescription(description);
        job.setDefinition(definition);
        job.setStepCount(countSteps(definition));
        applySchedule(job, schedule, scheduleTimezone);
        job.setRequiresApproval(Boolean.TRUE.equals(requiresApproval));
        job.setCreatedBy(actor);
        Job saved = jobRepository.save(job);
        log.info("Tenant {} created job {} ({} steps)", tenantId, saved.getId(), saved.getStepCount());
        return saved;
    }

    @Transactional
    public Job update(String tenantId, String accessToken, Long id, String name,
                      String jobGroup, String description, String definition, String schedule) {
        return update(tenantId, accessToken, id, name, jobGroup, description, definition,
                schedule, null);
    }

    @Transactional
    public Job update(String tenantId, String accessToken, Long id, String name,
                      String jobGroup, String description, String definition, String schedule,
                      Boolean requiresApproval) {
        return update(tenantId, accessToken, id, name, jobGroup, description, definition,
                schedule, null, requiresApproval);
    }

    @Transactional
    public Job update(String tenantId, String accessToken, Long id, String name,
                      String jobGroup, String description, String definition, String schedule,
                      String scheduleTimezone, Boolean requiresApproval) {
        gate.requireActive(accessToken);
        Job job = get(tenantId, id);
        if (name != null && !name.isBlank()) {
            job.setName(name);
        }
        if (jobGroup != null) {
            job.setJobGroup(jobGroup);
        }
        if (description != null) {
            job.setDescription(description);
        }
        if (definition != null) {
            job.setDefinition(definition);
            job.setStepCount(countSteps(definition));
        }
        // A timezone-only edit still has to recompute next_run_at — moving a job
        // from UTC to America/Chicago changes when "0 2 * * *" fires.
        if (schedule != null || scheduleTimezone != null) {
            applySchedule(job, schedule != null ? schedule : job.getSchedule(), scheduleTimezone);
        }
        if (requiresApproval != null) {
            job.setRequiresApproval(requiresApproval);
        }
        return jobRepository.save(job);
    }

    @Transactional
    public Job setEnabled(String tenantId, String accessToken, Long id, boolean enabled) {
        gate.requireActive(accessToken);
        Job job = get(tenantId, id);
        job.setEnabled(enabled);
        if (enabled && job.getSchedule() != null) {
            // Recompute so a long-paused job doesn't fire off a stale due time.
            job.setNextRunAt(CronSupport.next(job.getSchedule(), job.getScheduleTimezone()));
        }
        return jobRepository.save(job);
    }

    /** Deleting frees a MAX_JOBS slot. */
    @Transactional
    public void delete(String tenantId, String accessToken, Long id) {
        gate.requireActive(accessToken);
        Job job = get(tenantId, id);
        jobRepository.delete(job);
        log.info("Tenant {} deleted job {}", tenantId, id);
    }

    // ------------------------------------------------------------------

    /**
     * Blank schedule clears the schedule; anything else must be a valid cron
     * (400 if not). A blank timezone leaves the job's existing zone alone, so
     * callers that don't know about timezones can't silently reset one to UTC.
     */
    private void applySchedule(Job job, String schedule, String scheduleTimezone) {
        if (scheduleTimezone != null && !scheduleTimezone.isBlank()) {
            // getId() normalizes and validates in one step (400 on a bad zone).
            String resolved = CronSupport.zone(scheduleTimezone).getId();
            if (!resolved.equals(job.getScheduleTimezone())) {
                // last_fired_local is a wall-clock reading in the OLD zone;
                // keeping it would compare against a different clock.
                job.setLastFiredLocal(null);
                job.setScheduleTimezone(resolved);
            }
        }
        if (schedule == null || schedule.isBlank()) {
            job.setSchedule(null);
            job.setNextRunAt(null);
            return;
        }
        job.setSchedule(schedule.trim());
        job.setNextRunAt(CronSupport.next(schedule, job.getScheduleTimezone())); // validates too
    }

    private Project requireProject(String tenantId, Long projectId) {
        return projectRepository.findByIdAndTenantId(projectId, tenantId)
                .orElseThrow(() -> CoreException.notFound("project_not_found", "No such project"));
    }

    /** Server-side step count from the steps JSON's {@code steps} array. */
    int countSteps(String definition) {
        if (definition == null || definition.isBlank()) {
            return 0;
        }
        try {
            JsonNode root = objectMapper.readTree(definition);
            if (!root.isObject()) {
                throw CoreException.badRequest("invalid_definition",
                        "Job definition must be a JSON object");
            }
            return root.path("steps").size();
        } catch (CoreException ex) {
            throw ex;
        } catch (Exception ex) {
            throw CoreException.badRequest("invalid_definition",
                    "Job definition is not valid JSON");
        }
    }
}
