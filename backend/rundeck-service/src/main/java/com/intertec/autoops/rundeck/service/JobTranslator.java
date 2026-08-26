package com.intertec.autoops.rundeck.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.rundeck.exception.RundeckException;
import com.intertec.autoops.rundeck.web.dto.StepExecutionRequest;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Turns an AutoOps job into a REAL Rundeck job definition, ready to import.
 *
 * <p>This is the piece that moves job ownership onto the engine. Until now a
 * job existed only in {@code autoops_core.jobs} and each step was dispatched
 * ad-hoc at run time, so Rundeck's own JOBS screen was permanently empty and
 * its scheduler never fired anything. After this, an AutoOps job IS a Rundeck
 * job: it appears in the engine, carries its own schedule, and produces one
 * execution per run instead of one per step.
 *
 * <p><strong>The UUID is derived, never random.</strong> It is computed from
 * the tenant and the AutoOps job id, so re-importing the same job updates it in
 * place rather than accumulating a duplicate every time someone saves an edit —
 * and so the link survives even if the mapping row is lost.
 *
 * <p><strong>Step parsing mirrors core-service's run engine exactly</strong>
 * ({@code ExecutionEngine#steps}): the palette id lives in {@code id} on
 * designer-authored jobs and in {@code type} on older ones, so both are
 * accepted, in that order, with the same default label. A job that read
 * differently here than it does there would execute differently depending on
 * which path ran it, which is the one bug this class must not have.
 */
@Component
public class JobTranslator {

    /**
     * Namespace for derived job UUIDs. The tenant is part of the seed, not an
     * afterthought: without it, job 1 of tenant A and job 1 of tenant B would
     * collide on one UUID and silently overwrite each other on the engine.
     */
    private static final String UUID_SEED_PREFIX = "autoops-job:";

    /** Every AutoOps job lands in this Rundeck group, so one ACL glob covers them. */
    private static final String JOB_GROUP = "autoops";

    private final StepTranslator stepTranslator;
    private final ObjectMapper objectMapper;

    public JobTranslator(StepTranslator stepTranslator, ObjectMapper objectMapper) {
        this.stepTranslator = stepTranslator;
        this.objectMapper = objectMapper;
    }

    /** One AutoOps job, as much of it as the engine needs. */
    public record JobSpec(
            String tenantId,
            Long projectId,
            Long jobId,
            String name,
            String description,
            /** The job's {@code definition} column: {@code {"steps":[...]}}. */
            String definitionJson,
            /** Standard 5-field Unix cron, or null for an unscheduled job. */
            String cron,
            String timezone,
            boolean enabled,
            /**
             * When true, the engine records the schedule but must NOT fire it.
             * Rundeck cannot pause mid-schedule to ask a human, so AutoOps keeps
             * the cron for these jobs, raises the approval, and triggers the job
             * only once someone grants it.
             */
            boolean requiresApproval) {
    }

    /** The stable Rundeck job UUID for an AutoOps job. */
    public String uuidFor(String tenantId, Long jobId) {
        return UUID.nameUUIDFromBytes(
                        (UUID_SEED_PREFIX + tenantId + ":" + jobId).getBytes(StandardCharsets.UTF_8))
                .toString();
    }

    /**
     * The import payload: a LIST holding one job, which is the shape
     * {@code /project/{p}/jobs/import?format=json} expects. A bare object is
     * rejected with "Expected list data".
     */
    public List<Map<String, Object>> toRundeckJob(JobSpec spec) {
        List<Map<String, Object>> commands = commands(spec);
        if (commands.isEmpty()) {
            // The same refusal the ad-hoc path makes for an empty step body, for
            // the same reason: a job of no steps imports fine, runs green, and
            // does nothing at all.
            throw RundeckException.badRequest("job_has_no_steps",
                    "Job \"" + spec.name() + "\" has no runnable steps — "
                            + "fill in the step bodies before it can run on the engine.");
        }

        Map<String, Object> job = new LinkedHashMap<>();
        job.put("uuid", uuidFor(spec.tenantId(), spec.jobId()));
        job.put("name", spec.name());
        job.put("group", JOB_GROUP);
        job.put("description", spec.description() == null ? "" : spec.description());
        job.put("loglevel", "INFO");

        // Mirrors the AutoOps `enabled` flag. A disabled job stays VISIBLE on the
        // engine but refuses to run, rather than vanishing and reappearing on
        // every toggle — which would also destroy its execution history.
        job.put("executionEnabled", spec.enabled());

        Map<String, Object> sequence = new LinkedHashMap<>();
        // keepgoing=false matches the run engine's default: a failed step stops
        // the job. Per-step continueOnError has no equivalent here; the caller
        // handles those jobs rather than this silently dropping the flag.
        sequence.put("keepgoing", false);
        sequence.put("strategy", "node-first");
        sequence.put("commands", commands);
        job.put("sequence", sequence);

        applySchedule(job, spec);

        List<Map<String, Object>> payload = new ArrayList<>(1);
        payload.add(job);
        return payload;
    }

    private void applySchedule(Map<String, Object> job, JobSpec spec) {
        if (spec.cron() == null || spec.cron().isBlank()) {
            job.put("scheduleEnabled", false);
            return;
        }
        job.put("schedule", Map.of("crontab", CronConverter.toQuartz(spec.cron())));
        job.put("timeZone", spec.timezone() == null || spec.timezone().isBlank()
                ? "UTC" : spec.timezone());
        // THE APPROVAL RULE. An approval-gated job is imported with its schedule
        // recorded but the engine's scheduler switched off. Leaving this true
        // would run the job unapproved, on time, every time — the gate would
        // look present in AutoOps and do nothing.
        job.put("scheduleEnabled", spec.enabled() && !spec.requiresApproval());
    }

    /** One Rundeck command per AutoOps step, in order. */
    private List<Map<String, Object>> commands(JobSpec spec) {
        JsonNode items;
        try {
            items = objectMapper.readTree(
                    spec.definitionJson() == null ? "{}" : spec.definitionJson()).path("steps");
        } catch (Exception ex) {
            throw RundeckException.badRequest("job_definition_invalid",
                    "Could not read the job definition: " + ex.getMessage());
        }

        List<Map<String, Object>> commands = new ArrayList<>();
        for (int i = 0; i < items.size(); i++) {
            JsonNode item = items.get(i);
            // Identical to ExecutionEngine#steps — see the class javadoc.
            String type = item.path("type").asText(item.path("id").asText("step"));
            String label = item.path("label").asText(type + " " + (i + 1));

            @SuppressWarnings("unchecked")
            Map<String, Object> raw = objectMapper.convertValue(item, Map.class);

            StepTranslator.Script script = stepTranslator.translate(new StepExecutionRequest(
                    spec.tenantId(), spec.projectId(), null, i, type, label,
                    item.path("value").asText(null),
                    raw,
                    null,
                    // NO credentials at import time. They are resolved per run,
                    // decrypted for a single call and never persisted — baking
                    // them into a stored job definition would write a tenant's
                    // cloud keys onto the engine's disk, where every later run
                    // and every operator with project access could read them.
                    Map.of(),
                    null, null, null));

            Map<String, Object> command = new LinkedHashMap<>();
            command.put("description", label);
            command.put("script", script.body());
            command.put("scriptInterpreter", script.interpreter());
            commands.add(command);
        }
        return commands;
    }
}
