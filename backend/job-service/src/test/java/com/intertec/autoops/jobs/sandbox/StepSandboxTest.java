package com.intertec.autoops.jobs.sandbox;

import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.ProcessSupport;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * Sandbox behaviour that holds everywhere. The isolation itself — one OS user
 * per step — needs root and the pool users from the image; it is exercised in
 * the container (see the README's verification steps), not here.
 */
class StepSandboxTest {

    /**
     * CI runs this suite inside a root container with no step-user pool, where
     * the production policy is to refuse the step. Tests opt out of that
     * refusal; nothing else may.
     */
    private static JobProperties testProperties() {
        JobProperties properties = new JobProperties();
        properties.getSandbox().setAllowRootSteps(true);
        return properties;
    }

    @Test
    void isInactiveOnADevBoxAndSaysWhy() {
        StepSandbox sandbox = new StepSandbox(testProperties());

        assumeTrue(!sandbox.active(), "this machine can actually isolate steps");
        assertNotNull(sandbox.inactiveReason());
        assertFalse(sandbox.inactiveReason().isBlank());
    }

    @Test
    void stillGivesEveryStepItsOwnDirectory() throws Exception {
        StepSandbox sandbox = new StepSandbox(testProperties());

        Path first;
        Path second;
        try (StepWorkspace a = sandbox.acquire(); StepWorkspace b = sandbox.acquire()) {
            first = a.createFile("probe-", ".txt");
            second = b.createFile("probe-", ".txt");
            Files.writeString(first, "a");
            Files.writeString(second, "b");
            assertFalse(first.getParent().equals(second.getParent()),
                    "two concurrent steps shared a directory");
        }
        assertFalse(Files.exists(first), "workspace survived close()");
        assertFalse(Files.exists(second), "workspace survived close()");
    }

    @Test
    void pointsHomeAndTmpdirIntoTheWorkspace() throws Exception {
        StepSandbox sandbox = new StepSandbox(testProperties());

        try (StepWorkspace workspace = sandbox.acquire()) {
            assertEquals(workspace.workingDirectory().toAbsolutePath().toString(),
                    workspace.environment().get("HOME"));
            assertTrue(Files.isDirectory(Path.of(workspace.environment().get("TMPDIR"))));
        }
    }

    /** Without isolation the command must be left exactly as the runner built it. */
    @Test
    void doesNotWrapTheCommandWhenInactive() throws Exception {
        StepSandbox sandbox = new StepSandbox(testProperties());
        assumeTrue(!sandbox.active(), "this machine can actually isolate steps");

        try (StepWorkspace workspace = sandbox.acquire()) {
            List<String> command = List.of("echo", "hi");
            assertEquals(command, workspace.wrap(command));
            assertFalse(workspace.isolated());
        }
    }

    @Test
    void disabledWorkspaceIsUsableWithoutASandbox() throws Exception {
        StepWorkspace workspace = StepWorkspace.disabled();

        assertFalse(workspace.isolated());
        assertNull(workspace.workingDirectory());
        assertEquals(List.of("id"), workspace.wrap(List.of("id")));
        assertTrue(workspace.environment().isEmpty());

        Path file = workspace.createFile("probe-", ".txt");
        try {
            assertTrue(Files.exists(file));
        } finally {
            Files.deleteIfExists(file);
        }
        workspace.close();
    }

    /** Switching the sandbox off is a deliberate dev-box choice, not a silent one. */
    @Test
    void reportsWhenExplicitlyDisabled() {
        JobProperties properties = testProperties();
        properties.getSandbox().setEnabled(false);

        StepSandbox sandbox = new StepSandbox(properties);

        assertFalse(sandbox.active());
        assertTrue(sandbox.inactiveReason().contains("switched off"), sandbox.inactiveReason());
    }

    @Test
    void aStepRunsInsideItsWorkspace() throws Exception {
        StepSandbox sandbox = new StepSandbox(testProperties());

        try (StepWorkspace workspace = sandbox.acquire()) {
            String print = ProcessSupport.isWindows() ? "cd" : "pwd";
            ProcessSupport.ProcessResult result = ProcessSupport.run(
                    workspace.wrap(ProcessSupport.shellCommand(print)),
                    workspace.environment(), workspace.workingDirectory(),
                    java.time.Duration.ofSeconds(20), 4000, List.of());

            assertEquals(0, result.exitCode(), result.output());
            assertTrue(result.output().toLowerCase().contains(
                            workspace.workingDirectory().getFileName().toString().toLowerCase()),
                    result.output());
        }
    }
}
