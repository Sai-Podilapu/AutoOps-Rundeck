package com.intertec.autoops.jobs.sandbox;

import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.ProcessSupport;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.file.FileSystems;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.GroupPrincipal;
import java.nio.file.attribute.UserPrincipal;
import java.nio.file.attribute.UserPrincipalLookupService;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Hands each step its own OS user for the duration of the step.
 *
 * <p>Steps are tenant-authored code executing in one shared container. With a
 * single uid, file permissions are decoration: {@code /proc/<pid>/environ} and
 * a 0600 kubeconfig are both readable by any process with the same owner, so a
 * step could read a concurrent step's decrypted cloud credentials. Leasing a
 * distinct uid per step makes that a kernel-enforced denial.
 *
 * <p>Dropping privileges needs privileges: the container's PID 1 runs as root
 * and never executes tenant code itself — every step is exec'd through
 * {@code su-exec} as a pool user that owns nothing. Where that is not possible
 * (a dev box, a container started as a non-root user) the sandbox reports
 * itself inactive; if we are root and cannot isolate, steps are REFUSED rather
 * than run as root.
 */
@Component
public class StepSandbox {

    private static final Logger log = LoggerFactory.getLogger(StepSandbox.class);
    private static final List<String> SU_EXEC_CANDIDATES =
            List.of("/sbin/su-exec", "/usr/sbin/su-exec", "/bin/su-exec", "/usr/bin/su-exec");

    private final JobProperties properties;
    private final BlockingQueue<StepUser> pool;
    private final Path scratchRoot;
    private final boolean root;
    private final String inactiveReason;

    public StepSandbox(JobProperties properties) {
        this.properties = properties;
        this.scratchRoot = Path.of(properties.getSandbox().getScratchDir() != null
                ? properties.getSandbox().getScratchDir()
                : System.getProperty("java.io.tmpdir"));
        this.root = isRoot();
        List<StepUser> users = properties.getSandbox().isEnabled() ? resolveUsers() : List.of();
        this.pool = new ArrayBlockingQueue<>(Math.max(1, users.size()));
        this.pool.addAll(users);
        this.inactiveReason = users.isEmpty() ? describeWhyInactive() : null;
        logStartupState(users.size());
    }

    /** True when steps really are isolated from each other by the OS. */
    public boolean active() {
        return inactiveReason == null;
    }

    public String inactiveReason() {
        return inactiveReason;
    }

    /**
     * Leases a workspace for one step. Always paired with
     * {@link StepWorkspace#close()} — it returns the user to the pool, kills
     * anything the step left running under it, and deletes the scratch tree.
     *
     * @throws SandboxException when the step must not run: either we are root
     *                          with no way to drop privileges, or every pool
     *                          user is busy
     */
    public StepWorkspace acquire() throws SandboxException {
        if (!active()) {
            if (root && !properties.getSandbox().isAllowRootSteps()) {
                // Refusing beats running tenant commands as uid 0.
                throw new SandboxException("Step execution is disabled: " + inactiveReason
                        + ". Refusing to run steps as root.");
            }
            return unisolatedWorkspace();
        }
        StepUser user;
        try {
            user = pool.poll(properties.getSandbox().getLeaseTimeout().toMillis(),
                    TimeUnit.MILLISECONDS);
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            throw new SandboxException("Interrupted while waiting for an execution slot");
        }
        if (user == null) {
            throw new SandboxException("All " + pool.size() + " execution slots are busy — "
                    + "too many steps running at once, retry shortly");
        }
        try {
            return StepWorkspace.create(user, scratchRoot, () -> pool.add(user));
        } catch (IOException ex) {
            pool.add(user);
            throw new SandboxException("Could not prepare a step workspace: " + ex.getMessage());
        }
    }

    /** A private scratch directory, but no uid separation (dev boxes). */
    private StepWorkspace unisolatedWorkspace() throws SandboxException {
        try {
            return StepWorkspace.create(null, scratchRoot, () -> {
            });
        } catch (IOException ex) {
            throw new SandboxException("Could not prepare a step workspace: " + ex.getMessage());
        }
    }

    // ------------------------------------------------------------------

    private List<StepUser> resolveUsers() {
        if (ProcessSupport.isWindows() || !root) {
            return List.of();
        }
        String suExec = findSuExec();
        if (suExec == null) {
            return List.of();
        }
        UserPrincipalLookupService lookup = FileSystems.getDefault().getUserPrincipalLookupService();
        GroupPrincipal group;
        try {
            group = lookup.lookupPrincipalByGroupName(properties.getSandbox().getGroupName());
        } catch (IOException ex) {
            group = null; // the user's primary group is enough
        }
        List<StepUser> users = new ArrayList<>();
        for (int i = 1; i <= properties.getSandbox().getUserCount(); i++) {
            String name = properties.getSandbox().getUserPrefix() + i;
            try {
                UserPrincipal principal = lookup.lookupPrincipalByName(name);
                users.add(new StepUser(name, principal, group, suExec));
            } catch (IOException ex) {
                // Pool users are created in the image; a missing one just
                // means a smaller pool, not a broken sandbox.
                log.debug("Step user {} does not exist: {}", name, ex.getMessage());
            }
        }
        return users;
    }

    private static String findSuExec() {
        return SU_EXEC_CANDIDATES.stream()
                .filter(candidate -> Files.isExecutable(Path.of(candidate)))
                .findFirst()
                .orElse(null);
    }

    /** {@code id -u} — cheap, portable, and run exactly once at startup. */
    private static boolean isRoot() {
        if (ProcessSupport.isWindows()) {
            return false;
        }
        try {
            ProcessSupport.ProcessResult result = ProcessSupport.run(
                    List.of("id", "-u"), Duration.ofSeconds(5), 64);
            return result.exitCode() == 0 && "0".equals(result.output().trim());
        } catch (IOException | InterruptedException ex) {
            if (ex instanceof InterruptedException) {
                Thread.currentThread().interrupt();
            }
            return false;
        }
    }

    private String describeWhyInactive() {
        if (!properties.getSandbox().isEnabled()) {
            return "the per-step sandbox is switched off (autoops.jobs.sandbox.enabled=false)";
        }
        if (ProcessSupport.isWindows()) {
            return "per-step OS users are a POSIX feature and this is a Windows host";
        }
        if (!root) {
            return "job-service is not running as root, so it cannot drop to a per-step user";
        }
        if (findSuExec() == null) {
            return "su-exec is not installed in this image";
        }
        return "no step users exist (expected " + properties.getSandbox().getUserPrefix()
                + "1.." + properties.getSandbox().getUserCount() + ")";
    }

    private void logStartupState(int poolSize) {
        if (active()) {
            log.info("Step sandbox active: {} per-step users ({}1..{}), scratch under {}",
                    poolSize, properties.getSandbox().getUserPrefix(), poolSize, scratchRoot);
        } else if (root && properties.getSandbox().isAllowRootSteps()) {
            log.error("Step sandbox INACTIVE and allow-root-steps is set — tenant commands will "
                    + "run as ROOT. This is only ever acceptable in a test container. {}",
                    inactiveReason);
        } else if (root) {
            log.error("Step sandbox INACTIVE and running as root — every step will be REFUSED. {}",
                    inactiveReason);
        } else {
            log.warn("Step sandbox inactive ({}). Steps share one OS user, so a step can read "
                    + "another step's scratch credentials — acceptable for local development "
                    + "only.", inactiveReason);
        }
    }
}
