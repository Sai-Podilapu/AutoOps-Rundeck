package com.intertec.autoops.jobs.sandbox;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.GroupPrincipal;
import java.nio.file.attribute.PosixFileAttributeView;
import java.nio.file.attribute.PosixFilePermissions;
import java.nio.file.attribute.UserPrincipal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;

/**
 * One step's private working area. When the sandbox is active this is a
 * directory owned by a throwaway OS user that only this step runs as, so a
 * decrypted kubeconfig or service-account key written here is unreadable by
 * any other step — including a concurrent step belonging to another tenant.
 *
 * <p>When the sandbox is inactive (Windows dev box, plain {@code mvn
 * spring-boot:run}) the workspace still gives every step a private directory
 * that is deleted afterwards, but every step runs as the same OS user, so the
 * separation is bookkeeping rather than a boundary.
 */
public final class StepWorkspace implements AutoCloseable {

    private static final Logger log = LoggerFactory.getLogger(StepWorkspace.class);

    /** Null when the sandbox is inactive. */
    private final StepUser user;
    /** Null only for the shared disabled instance, which owns no directory. */
    private final Path root;
    private final Path home;
    private final Path temp;
    private final Runnable release;

    private StepWorkspace(StepUser user, Path root, Path home, Path temp, Runnable release) {
        this.user = user;
        this.root = root;
        this.home = home;
        this.temp = temp;
        this.release = release;
    }

    /** No directory, no isolation — for tests and for callers with no sandbox. */
    public static StepWorkspace disabled() {
        return new StepWorkspace(null, null, null, null, () -> {
        });
    }

    static StepWorkspace create(StepUser user, Path parent, Runnable release) throws IOException {
        Path root = Files.createTempDirectory(parent, "autoops-step-");
        Path home = Files.createDirectory(root.resolve("home"));
        Path temp = Files.createDirectory(root.resolve("tmp"));
        StepWorkspace workspace = new StepWorkspace(user, root, home, temp, release);
        workspace.restrict(root);
        workspace.handOver(root);
        return workspace;
    }

    /** True when this step really does run as its own OS user. */
    public boolean isolated() {
        return user != null;
    }

    /**
     * Where the step should run. A writable directory of its own beats the
     * service's install directory, which the step user cannot write to.
     * Null when there is no workspace — the caller then inherits the JVM's.
     */
    public Path workingDirectory() {
        return home;
    }

    /**
     * A file inside the workspace. Prefer this over
     * {@link Files#createTempFile} for anything a step reads: a file in the
     * shared temp directory is readable by every other step.
     */
    public Path createFile(String prefix, String suffix) throws IOException {
        if (root == null) {
            return Files.createTempFile(prefix, suffix);
        }
        Path file = Files.createTempFile(temp, prefix, suffix);
        restrict(file);
        handOver(file);
        return file;
    }

    public Path createDirectory(String prefix) throws IOException {
        if (root == null) {
            return Files.createTempDirectory(prefix);
        }
        Path directory = Files.createTempDirectory(temp, prefix);
        restrict(directory);
        handOver(directory);
        return directory;
    }

    /**
     * Gives the step user ownership of everything under {@code path}. Call it
     * after writing content: a file the service creates inside an already
     * handed-over directory belongs to the service, not to the step, and the
     * step would get "permission denied" on its own script.
     */
    public void handOver(Path path) throws IOException {
        if (user == null || path == null || !Files.exists(path)) {
            return;
        }
        Files.walkFileTree(path, new SimpleFileVisitor<>() {
            @Override
            public FileVisitResult visitFile(Path file, BasicFileAttributes attributes)
                    throws IOException {
                chown(file);
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult postVisitDirectory(Path directory, IOException failure)
                    throws IOException {
                chown(directory);
                return FileVisitResult.CONTINUE;
            }
        });
    }

    /**
     * Prefixes the command so it runs as this step's own user.
     *
     * <p>{@code env HOME=…} after the drop is not belt-and-braces: su-exec
     * overwrites HOME with the pool user's passwd home, which deliberately
     * does not exist. Left alone, every tool that writes a dotfile or a cache
     * — terraform, ssh, pip — fails on a missing home directory.
     */
    public List<String> wrap(List<String> command) {
        if (user == null) {
            return command;
        }
        List<String> wrapped = new ArrayList<>(command.size() + 5);
        wrapped.add(user.suExecPath());
        wrapped.add(user.name());
        wrapped.add("env");
        wrapped.add("HOME=" + home.toAbsolutePath());
        wrapped.add("TMPDIR=" + temp.toAbsolutePath());
        wrapped.addAll(command);
        return wrapped;
    }

    /**
     * HOME and TMPDIR pointing inside the workspace, so a step's dotfiles,
     * caches and scratch files land where only it can read them and vanish
     * with the workspace.
     */
    public Map<String, String> environment() {
        if (root == null) {
            return Map.of();
        }
        return Map.of("HOME", home.toAbsolutePath().toString(),
                "TMPDIR", temp.toAbsolutePath().toString());
    }

    @Override
    public void close() {
        try {
            killLeftovers();
            deleteTree();
        } finally {
            release.run();
        }
    }

    /**
     * The timeout kills the step's process tree, but a step that daemonises
     * something can still leave a stray behind. Owning a whole OS user means
     * we can sweep by owner and be sure nothing of this step's survives to see
     * the next tenant's workspace.
     */
    private void killLeftovers() {
        if (user == null) {
            return;
        }
        ProcessHandle.allProcesses()
                .filter(handle -> user.name().equals(handle.info().user().orElse(null)))
                .forEach(handle -> {
                    log.warn("Killing leftover process {} owned by {}", handle.pid(), user.name());
                    handle.destroyForcibly();
                });
    }

    private void deleteTree() {
        if (root == null) {
            return;
        }
        try (var paths = Files.walk(root)) {
            paths.sorted(Comparator.reverseOrder()).forEach(path -> {
                try {
                    Files.deleteIfExists(path);
                } catch (IOException ignored) {
                    // scratch — best effort
                }
            });
        } catch (IOException ex) {
            log.warn("Could not delete step workspace {}: {}", root, ex.getMessage());
        }
    }

    /** Owner-only access; the sticky shared temp directory is not a boundary. */
    private void restrict(Path path) throws IOException {
        PosixFileAttributeView view =
                Files.getFileAttributeView(path, PosixFileAttributeView.class);
        if (view != null) {
            view.setPermissions(Files.isDirectory(path)
                    ? PosixFilePermissions.fromString("rwx------")
                    : PosixFilePermissions.fromString("rw-------"));
        }
    }

    private void chown(Path path) throws IOException {
        PosixFileAttributeView view =
                Files.getFileAttributeView(path, PosixFileAttributeView.class);
        if (view == null) {
            return;
        }
        UserPrincipal owner = user.principal();
        GroupPrincipal group = user.group();
        view.setOwner(owner);
        if (group != null) {
            view.setGroup(group);
        }
    }
}
