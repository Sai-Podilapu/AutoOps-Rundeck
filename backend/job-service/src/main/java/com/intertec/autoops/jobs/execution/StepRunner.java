package com.intertec.autoops.jobs.execution;

import com.fasterxml.jackson.databind.JsonNode;
import com.intertec.autoops.jobs.sandbox.StepWorkspace;

import java.time.Duration;
import java.util.Set;

/**
 * One strategy per step type — the Rundeck-style dispatch point. Runners are
 * discovered as beans; {@link com.intertec.autoops.jobs.service.StepExecutionService}
 * picks the first whose {@link #types()} contains the step's type.
 */
public interface StepRunner {

    /**
     * What the runner executes: type, free-text config, wall-clock limit,
     * (for cloud steps) the decrypted credential bundle
     * {@code {platform, connection, data{...}}} resolved by core-service, and
     * the private workspace this step runs in. Scratch files — scripts,
     * kubeconfigs, terraform workspaces — belong in the workspace, never in
     * the shared temp directory.
     */
    record StepCommand(String tenantId, String stepType, String label,
                       String value, JsonNode raw, Duration timeout, JsonNode credentials,
                       StepWorkspace workspace) {

        /** Without a workspace: the caller has not entered the sandbox yet. */
        public StepCommand(String tenantId, String stepType, String label, String value,
                           JsonNode raw, Duration timeout, JsonNode credentials) {
            this(tenantId, stepType, label, value, raw, timeout, credentials,
                    StepWorkspace.disabled());
        }
    }

    /** Raw outcome — output is truncated and timed by the service layer. */
    record StepResult(boolean success, String output, String error, Integer exitCode) {

        public static StepResult ok(String output, Integer exitCode) {
            return new StepResult(true, output, null, exitCode);
        }

        public static StepResult failed(String error, String output, Integer exitCode) {
            return new StepResult(false, output, error, exitCode);
        }
    }

    Set<String> types();

    StepResult run(StepCommand command) throws Exception;
}
