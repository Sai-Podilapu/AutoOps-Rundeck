package com.intertec.autoops.rundeck.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.rundeck.exception.RundeckException;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class JobTranslatorTest {

    private static final String TENANT = "intertec-systems-1542f8a3";

    private final JobTranslator translator =
            new JobTranslator(new StepTranslator(), new ObjectMapper());

    /** Two steps with real bodies, in the designer's own shape ({@code id}, not {@code type}). */
    private static final String DEFINITION = """
            {"steps":[
              {"id":"script","label":"Freeze business date","value":"echo freeze"},
              {"id":"script","label":"Interest accrual","value":"echo accrue"}
            ]}""";

    private JobTranslator.JobSpec spec(String cron, boolean enabled, boolean approval) {
        return new JobTranslator.JobSpec(TENANT, 9001L, 9101L, "Core Banking EOD Batch Close",
                "Nightly close", DEFINITION, cron, "Asia/Kolkata", enabled, approval);
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> job(JobTranslator.JobSpec spec) {
        List<Map<String, Object>> payload = translator.toRundeckJob(spec);
        // Rundeck rejects a bare object with "Expected list data".
        assertEquals(1, payload.size(), "import payload must be a list of one job");
        return payload.get(0);
    }

    @Test
    @DisplayName("the UUID is derived, so re-import updates instead of duplicating")
    void uuidIsStableAcrossCalls() {
        String first = translator.uuidFor(TENANT, 9101L);
        String second = translator.uuidFor(TENANT, 9101L);
        assertEquals(first, second);
        assertEquals(first, job(spec("30 23 * * 1-5", true, false)).get("uuid"));
    }

    @Test
    @DisplayName("the same job id in two tenants must not collide on one engine job")
    void uuidIsTenantScoped() {
        assertFalse(translator.uuidFor("tenant-a", 1L).equals(translator.uuidFor("tenant-b", 1L)));
    }

    @Test
    void convertsTheScheduleAndCarriesTheTimezone() {
        Map<String, Object> job = job(spec("30 23 * * 1-5", true, false));
        assertEquals(Map.of("crontab", "0 30 23 ? * MON-FRI"), job.get("schedule"));
        assertEquals("Asia/Kolkata", job.get("timeZone"));
        assertEquals(true, job.get("scheduleEnabled"));
    }

    @Test
    @DisplayName("an approval-gated job is imported with its schedule OFF")
    void approvalJobsAreNotScheduledOnTheEngine() {
        // The gate would otherwise be decorative: Rundeck cannot stop and wait
        // for a human, so an enabled schedule runs the job unapproved, on time.
        Map<String, Object> job = job(spec("30 23 * * 1-5", true, true));
        assertEquals(Map.of("crontab", "0 30 23 ? * MON-FRI"), job.get("schedule"),
                "the schedule is still recorded, so AutoOps can fire it after approval");
        assertEquals(false, job.get("scheduleEnabled"));
    }

    @Test
    void aDisabledJobIsNeitherScheduledNorRunnable() {
        Map<String, Object> job = job(spec("30 23 * * 1-5", false, false));
        assertEquals(false, job.get("scheduleEnabled"));
        assertEquals(false, job.get("executionEnabled"));
    }

    @Test
    void anUnscheduledJobImportsWithNoSchedule() {
        Map<String, Object> job = job(spec(null, true, false));
        assertFalse(job.containsKey("schedule"));
        assertEquals(false, job.get("scheduleEnabled"));
    }

    @Test
    @SuppressWarnings("unchecked")
    @DisplayName("every step becomes one command, in order, with its script body")
    void stepsBecomeCommandsInOrder() {
        Map<String, Object> sequence =
                (Map<String, Object>) job(spec("0 4 * * *", true, false)).get("sequence");
        List<Map<String, Object>> commands = (List<Map<String, Object>>) sequence.get("commands");

        assertEquals(2, commands.size());
        assertEquals("Freeze business date", commands.get(0).get("description"));
        assertEquals("Interest accrual", commands.get(1).get("description"));
        assertTrue(((String) commands.get(0).get("script")).contains("echo freeze"));
        assertTrue(((String) commands.get(1).get("script")).contains("echo accrue"));
        assertEquals("/bin/bash", commands.get(0).get("scriptInterpreter"));
        assertEquals(false, sequence.get("keepgoing"), "a failed step must stop the job");
    }

    @Test
    @DisplayName("older definitions using `type` parse the same as designer ones using `id`")
    void acceptsBothDefinitionShapes() {
        // ExecutionEngine reads type-then-id; so must this, or a job would run
        // differently depending on which path executed it.
        String legacy = "{\"steps\":[{\"type\":\"script\",\"label\":\"Legacy\",\"value\":\"echo hi\"}]}";
        var spec = new JobTranslator.JobSpec(TENANT, 9001L, 42L, "Legacy job", null,
                legacy, null, "UTC", true, false);
        @SuppressWarnings("unchecked")
        Map<String, Object> sequence = (Map<String, Object>) job(spec).get("sequence");
        @SuppressWarnings("unchecked")
        List<Map<String, Object>> commands = (List<Map<String, Object>>) sequence.get("commands");
        assertEquals("Legacy", commands.get(0).get("description"));
    }

    @Test
    @DisplayName("credentials are never written into a stored job definition")
    void noCredentialsAreBakedIn() {
        @SuppressWarnings("unchecked")
        Map<String, Object> sequence =
                (Map<String, Object>) job(spec("0 4 * * *", true, false)).get("sequence");
        @SuppressWarnings("unchecked")
        List<Map<String, Object>> commands = (List<Map<String, Object>>) sequence.get("commands");
        for (Map<String, Object> command : commands) {
            assertFalse(((String) command.get("script")).contains("export "),
                    "a stored job must not carry a tenant's decrypted credentials");
        }
    }

    @Test
    @DisplayName("the empty-step job is refused, not imported as a green no-op")
    void refusesAJobWithNoSteps() {
        // This is the state 12 of the 13 real jobs are in today: steps with a
        // label and no body. Importing them would produce jobs that succeed
        // while doing nothing.
        var empty = new JobTranslator.JobSpec(TENANT, 9001L, 9102L, "SWIFT MT940 Ingestion",
                null, "{\"steps\":[]}", "0 */2 * * *", "Asia/Kolkata", true, false);
        RundeckException ex = assertThrows(RundeckException.class,
                () -> translator.toRundeckJob(empty));
        assertEquals("job_has_no_steps", ex.getError());
    }

    @Test
    void refusesAnUnreadableDefinition() {
        var broken = new JobTranslator.JobSpec(TENANT, 9001L, 1L, "Broken", null,
                "{not json", null, "UTC", true, false);
        assertThrows(RundeckException.class, () -> translator.toRundeckJob(broken));
    }
}
