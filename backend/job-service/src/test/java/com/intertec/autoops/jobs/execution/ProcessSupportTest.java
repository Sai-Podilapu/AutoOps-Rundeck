package com.intertec.autoops.jobs.execution;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * The containment properties of running someone else's command: what it can
 * see (nothing of ours) and what happens when it refuses to stop.
 */
class ProcessSupportTest {

    // ---- the environment a step is handed ----

    @Test
    void dropsEverythingOutsideTheAllowlist() {
        Map<String, String> environment = new HashMap<>();
        environment.put("PATH", "/usr/bin");
        environment.put("HOME", "/home/autoops");
        environment.put("JOB_INTERNAL_TOKEN", "s3cret");
        environment.put("SENDGRID_API_KEY", "SG.xxx");
        environment.put("AWS_SECRET_ACCESS_KEY", "leak");

        ProcessSupport.scrubEnvironment(environment, List.of());

        assertEquals(Map.of("PATH", "/usr/bin", "HOME", "/home/autoops"), environment);
    }

    @Test
    void keepsWhatTheOperatorExplicitlyAllows() {
        Map<String, String> environment = new HashMap<>();
        environment.put("PATH", "/usr/bin");
        environment.put("HTTPS_PROXY", "http://proxy:3128");
        environment.put("JOB_INTERNAL_TOKEN", "s3cret");

        // Nulls and blanks are what a half-filled YAML list actually produces.
        ProcessSupport.scrubEnvironment(environment, Arrays.asList("HTTPS_PROXY", "  ", null));

        assertEquals("http://proxy:3128", environment.get("HTTPS_PROXY"));
        assertFalse(environment.containsKey("JOB_INTERNAL_TOKEN"));
    }

    /**
     * The end-to-end version: a real child process must not be able to read a
     * variable this JVM has. Picks whatever non-allowlisted variable the test
     * JVM actually carries, so it works on any machine.
     */
    @Test
    void aRealChildCannotReadOurEnvironment() throws Exception {
        Optional<Map.Entry<String, String>> secret = System.getenv().entrySet().stream()
                .filter(e -> e.getValue() != null && e.getValue().length() > 3)
                .filter(e -> !isAllowlisted(e.getKey()))
                .findFirst();
        assumeTrue(secret.isPresent(), "this JVM has no non-allowlisted environment variable");
        String name = secret.get().getKey();
        String value = secret.get().getValue();

        String echo = ProcessSupport.isWindows() ? "echo %" + name + "%" : "echo \"$" + name + "\"";
        ProcessSupport.ProcessResult result = ProcessSupport.run(
                ProcessSupport.shellCommand(echo), Duration.ofSeconds(20), 4000);

        assertFalse(result.output().contains(value),
                "step saw " + name + " from the service environment: " + result.output());
    }

    @Test
    void stillPassesTheRunnersOwnVariables() throws Exception {
        String echo = ProcessSupport.isWindows() ? "echo %STEP_MARKER%" : "echo \"$STEP_MARKER\"";
        ProcessSupport.ProcessResult result = ProcessSupport.run(
                ProcessSupport.shellCommand(echo), Map.of("STEP_MARKER", "visible"),
                null, Duration.ofSeconds(20), 4000);

        assertTrue(result.output().contains("visible"), result.output());
    }

    // ---- what a timeout actually kills ----

    /**
     * A step that backgrounds work used to survive its own timeout: killing
     * the shell left the grandchild running. The marker file is written two
     * seconds after the step is killed — if it ever appears, the kill missed.
     */
    @Test
    void killsGrandchildrenWhenTheStepTimesOut() throws Exception {
        assumeTrue(!ProcessSupport.isWindows(), "POSIX job control — verified in the Linux image");
        Path marker = Files.createTempFile("autoops-orphan-", ".marker");
        Files.delete(marker);

        ProcessSupport.ProcessResult result = ProcessSupport.run(
                ProcessSupport.shellCommand(
                        "( sleep 2; touch " + marker.toAbsolutePath() + " ) & sleep 30"),
                Duration.ofSeconds(1), 4000);

        assertTrue(result.timedOut());
        Thread.sleep(4000);
        assertFalse(Files.exists(marker),
                "a backgrounded grandchild outlived the step timeout");
    }

    @Test
    void capturesOutputUpToTheCap() throws Exception {
        ProcessSupport.ProcessResult result = ProcessSupport.run(
                ProcessSupport.shellCommand("echo hello-from-the-step"),
                Duration.ofSeconds(20), 4000);

        assertEquals(0, result.exitCode());
        assertFalse(result.timedOut());
        assertTrue(result.output().contains("hello-from-the-step"));
    }

    private static boolean isAllowlisted(String name) {
        Map<String, String> probe = new HashMap<>();
        probe.put(name, "x");
        ProcessSupport.scrubEnvironment(probe, List.of());
        return !probe.isEmpty();
    }
}
