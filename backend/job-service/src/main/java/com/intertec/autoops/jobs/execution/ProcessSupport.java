package com.intertec.autoops.jobs.execution;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Collection;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.concurrent.TimeUnit;

/**
 * Runs OS processes with a hard wall-clock limit and a capped, merged
 * stdout+stderr capture. OS-aware so the same runners work in the Linux
 * container (bash/sh) and on a Windows dev machine (cmd.exe).
 *
 * <p><b>Steps never inherit this service's environment.</b> A step is tenant
 * -authored code; handing it {@code JOB_INTERNAL_TOKEN} (or anything else in
 * the container's environment) would leak a platform secret into a run log the
 * tenant can read. Children get an allowlisted base environment plus exactly
 * what the runner passes in.
 */
public final class ProcessSupport {

    /**
     * The bare minimum a shell, python, kubectl or terraform needs to work.
     * Everything else — tokens, keys, build-agent variables — is dropped.
     * {@code SystemRoot} and friends are Windows-only: cmd.exe cannot start
     * without them, and Windows is a dev-box concern, not a tenant boundary.
     */
    private static final List<String> BASE_ENVIRONMENT = List.of(
            "PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "TMPDIR",
            "SystemRoot", "SystemDrive", "COMSPEC", "PATHEXT", "windir",
            "TEMP", "TMP", "USERPROFILE", "NUMBER_OF_PROCESSORS",
            "PROCESSOR_ARCHITECTURE");

    public record ProcessResult(int exitCode, String output, boolean timedOut) {
    }

    private ProcessSupport() {
    }

    public static boolean isWindows() {
        return System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win");
    }

    /** The platform's one-liner shell invocation for a command string. */
    public static List<String> shellCommand(String commandLine) {
        if (isWindows()) {
            return List.of("cmd.exe", "/c", commandLine);
        }
        return Files.isExecutable(Path.of("/bin/bash"))
                ? List.of("/bin/bash", "-lc", commandLine)
                : List.of("/bin/sh", "-c", commandLine);
    }

    /** Shell invocation for a script FILE written by a runner. */
    public static List<String> scriptCommand(Path scriptFile) {
        if (isWindows()) {
            return List.of("cmd.exe", "/c", scriptFile.toAbsolutePath().toString());
        }
        String shell = Files.isExecutable(Path.of("/bin/bash")) ? "/bin/bash" : "/bin/sh";
        return List.of(shell, scriptFile.toAbsolutePath().toString());
    }

    public static String scriptExtension() {
        return isWindows() ? ".bat" : ".sh";
    }

    public static ProcessResult run(List<String> command, Duration timeout, int maxChars)
            throws IOException, InterruptedException {
        return run(command, null, null, timeout, maxChars, List.of());
    }

    public static ProcessResult run(List<String> command, Map<String, String> env,
                                    Path workDir, Duration timeout, int maxChars)
            throws IOException, InterruptedException {
        return run(command, env, workDir, timeout, maxChars, List.of());
    }

    /**
     * Full form: extra environment variables, a working directory, and the
     * operator's additional environment passthrough
     * ({@code autoops.jobs.env-passthrough}) for variables a site genuinely
     * needs in every step — proxies, a terraform plugin cache, and the like.
     */
    public static ProcessResult run(List<String> command, Map<String, String> env,
                                    Path workDir, Duration timeout, int maxChars,
                                    Collection<String> envPassthrough)
            throws IOException, InterruptedException {
        ProcessBuilder builder = new ProcessBuilder(command);
        builder.redirectErrorStream(true); // merged stdout+stderr, Rundeck-style log
        scrubEnvironment(builder.environment(), envPassthrough);
        if (env != null) {
            builder.environment().putAll(env);
        }
        if (workDir != null) {
            builder.directory(workDir.toFile());
        }
        Process process = builder.start();
        process.getOutputStream().close(); // no stdin: commands must not block on reads

        // StringBuffer, not StringBuilder: the drain runs on another thread and
        // a step that leaks a child holding the pipe can still be appending
        // when the join below gives up and we read the result.
        StringBuffer output = new StringBuffer();
        Thread reader = Thread.ofVirtual().start(() -> drain(process.getInputStream(), output, maxChars));

        boolean finished = process.waitFor(timeout.toMillis(), TimeUnit.MILLISECONDS);
        if (!finished) {
            destroyTree(process);
        }
        reader.join(Duration.ofSeconds(5).toMillis());
        return new ProcessResult(finished ? process.exitValue() : -1,
                output.toString(), !finished);
    }

    /**
     * Kills the whole process tree, not just the shell we started. Descendants
     * are collected FIRST: once the parent dies its children are reparented and
     * {@code descendants()} can no longer find them, which is how a backgrounded
     * step used to outlive its own timeout.
     */
    private static void destroyTree(Process process) throws InterruptedException {
        List<ProcessHandle> descendants = process.descendants().toList();
        process.destroyForcibly();
        descendants.forEach(ProcessHandle::destroyForcibly);
        process.waitFor(5, TimeUnit.SECONDS);
        // A second sweep catches anything spawned while the first pass ran.
        process.descendants().forEach(ProcessHandle::destroyForcibly);
        descendants.forEach(handle -> {
            if (handle.isAlive()) {
                handle.destroyForcibly();
            }
        });
    }

    /**
     * Drops every inherited variable except the allowlist. The map is
     * case-insensitive on Windows and case-sensitive on POSIX; comparing
     * case-insensitively is right on Windows and harmless on POSIX, where the
     * allowlist entries are already the canonical spellings.
     */
    static void scrubEnvironment(Map<String, String> environment,
                                 Collection<String> envPassthrough) {
        Set<String> allowed = new TreeSet<>(String.CASE_INSENSITIVE_ORDER);
        allowed.addAll(BASE_ENVIRONMENT);
        if (envPassthrough != null) {
            envPassthrough.stream().filter(name -> name != null && !name.isBlank())
                    .map(String::trim).forEach(allowed::add);
        }
        environment.keySet().removeIf(name -> !allowed.contains(name));
    }

    private static void drain(InputStream in, StringBuffer sink, int maxChars) {
        try (in) {
            byte[] buffer = new byte[8192];
            int read;
            while ((read = in.read(buffer)) >= 0) {
                if (sink.length() < maxChars) {
                    String chunk = new String(buffer, 0, read, StandardCharsets.UTF_8);
                    int room = maxChars - sink.length();
                    sink.append(chunk, 0, Math.min(chunk.length(), room));
                    if (sink.length() >= maxChars) {
                        sink.append("\n… output truncated …");
                    }
                }
                // keep draining even when capped so the process never blocks on a full pipe
            }
        } catch (IOException ignored) {
            // stream closed by process death — the captured prefix is what we have
        }
    }
}
