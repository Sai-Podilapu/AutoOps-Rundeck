package com.intertec.autoops.jobs.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;

/** All job-service settings, kebab-case under {@code autoops.jobs.*}. */
@ConfigurationProperties("autoops.jobs")
public class JobProperties {

    /** Dev default — ProdSafetyGuard refuses to start prod with it. */
    public static final String DEV_TOKEN = "dev-internal-token";

    /**
     * Shared secret core-service must present in X-Internal-Token. This
     * service executes arbitrary commands BY DESIGN — it must only ever be
     * reachable from inside the platform network, and only with this token.
     */
    private String internalToken = DEV_TOKEN;

    /** Per-step wall-clock limit when the caller doesn't send one. */
    private Duration defaultStepTimeout = Duration.ofSeconds(60);

    /** Hard ceiling — callers cannot ask for more than this. */
    private Duration maxStepTimeout = Duration.ofMinutes(10);

    /** Captured output cap per step (stdout+stderr merged). */
    private int outputMaxChars = 16_000;

    /**
     * Environment variables a step is allowed to inherit from this service, on
     * top of the base set (PATH, HOME, LANG, TZ, TMPDIR). Steps are tenant
     * code: everything not listed here is stripped, which is what keeps
     * JOB_INTERNAL_TOKEN out of a run log. Add site-wide needs such as
     * HTTPS_PROXY or TF_PLUGIN_CACHE_DIR — never a secret.
     */
    private List<String> envPassthrough = new ArrayList<>();

    private final Sandbox sandbox = new Sandbox();

    /** Per-step OS-user isolation — see {@code jobs.sandbox.StepSandbox}. */
    public static class Sandbox {

        /** false = never isolate (development only; root still refuses to run steps). */
        private boolean enabled = true;

        /** Pool users, created in the image as {@code autoops-step1..N}. */
        private String userPrefix = "autoops-step";

        private String groupName = "autoops-steps";

        /**
         * Size of the pool, and therefore the ceiling on concurrent steps —
         * core-service's execution pool should not exceed it.
         */
        private int userCount = 8;

        /** How long a step waits for a free slot before failing honestly. */
        private Duration leaseTimeout = Duration.ofSeconds(30);

        /** Where step workspaces are created; null = the JVM's temp directory. */
        private String scratchDir;

        /**
         * Run steps as root when isolation is unavailable, instead of
         * refusing them. This exists for test suites and CI, which commonly
         * run inside a root container with no step-user pool. NEVER true in a
         * deployment: it hands tenant-authored commands uid 0. The prod
         * profile refuses to start without a working sandbox regardless.
         */
        private boolean allowRootSteps;

        public boolean isEnabled() {
            return enabled;
        }

        public void setEnabled(boolean enabled) {
            this.enabled = enabled;
        }

        public String getUserPrefix() {
            return userPrefix;
        }

        public void setUserPrefix(String userPrefix) {
            this.userPrefix = userPrefix;
        }

        public String getGroupName() {
            return groupName;
        }

        public void setGroupName(String groupName) {
            this.groupName = groupName;
        }

        public int getUserCount() {
            return userCount;
        }

        public void setUserCount(int userCount) {
            this.userCount = userCount;
        }

        public Duration getLeaseTimeout() {
            return leaseTimeout;
        }

        public void setLeaseTimeout(Duration leaseTimeout) {
            this.leaseTimeout = leaseTimeout;
        }

        public String getScratchDir() {
            return scratchDir;
        }

        public void setScratchDir(String scratchDir) {
            this.scratchDir = scratchDir;
        }

        public boolean isAllowRootSteps() {
            return allowRootSteps;
        }

        public void setAllowRootSteps(boolean allowRootSteps) {
            this.allowRootSteps = allowRootSteps;
        }
    }

    public List<String> getEnvPassthrough() {
        return envPassthrough;
    }

    public void setEnvPassthrough(List<String> envPassthrough) {
        this.envPassthrough = envPassthrough;
    }

    public Sandbox getSandbox() {
        return sandbox;
    }

    public String getInternalToken() {
        return internalToken;
    }

    public void setInternalToken(String internalToken) {
        this.internalToken = internalToken;
    }

    public Duration getDefaultStepTimeout() {
        return defaultStepTimeout;
    }

    public void setDefaultStepTimeout(Duration defaultStepTimeout) {
        this.defaultStepTimeout = defaultStepTimeout;
    }

    public Duration getMaxStepTimeout() {
        return maxStepTimeout;
    }

    public void setMaxStepTimeout(Duration maxStepTimeout) {
        this.maxStepTimeout = maxStepTimeout;
    }

    public int getOutputMaxChars() {
        return outputMaxChars;
    }

    public void setOutputMaxChars(int outputMaxChars) {
        this.outputMaxChars = outputMaxChars;
    }
}
