package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.intertec.autoops.core.client.WorkflowClient;
import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.domain.ScmConfig;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.ScmConfigRepository;
import org.eclipse.jgit.api.Git;
import org.eclipse.jgit.api.PushCommand;
import org.eclipse.jgit.api.errors.TransportException;
import org.eclipse.jgit.lib.Constants;
import org.eclipse.jgit.revwalk.RevCommit;
import org.eclipse.jgit.transport.CredentialsProvider;
import org.eclipse.jgit.transport.PushResult;
import org.eclipse.jgit.transport.RemoteRefUpdate;
import org.eclipse.jgit.transport.UsernamePasswordCredentialsProvider;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.stream.Stream;

/**
 * Real git sync for a project's automation definitions. Export clones the
 * configured repo, REPLACES {@code basePath/jobs} and {@code basePath/workflows}
 * with one pretty-printed JSON file per definition (so deletes and renames
 * sync too), commits and pushes. Import reads those files back and upserts
 * through JobService/WorkflowService — so plan quotas and validation still
 * apply, and per-file failures are reported, not fatal. Config writes are
 * ADMIN-only (the token lives here, AES-GCM encrypted at rest); export and
 * import are open to members with an active subscription. http(s) and file
 * remotes only.
 */
@Service
public class ScmService {

    public enum ImportStrategy { OVERWRITE, SKIP }

    public record ExportResult(int jobs, int workflows, boolean pushed, String commitId) {
    }

    public record ImportResult(int created, int updated, int skipped, List<String> errors) {
    }

    private static final Logger log = LoggerFactory.getLogger(ScmService.class);
    private static final int GIT_TIMEOUT_SECONDS = 60;

    private final ScmConfigRepository scmConfigRepository;
    private final ProjectService projectService;
    private final JobService jobService;
    private final WorkflowClient workflowClient;
    private final SubscriptionGate gate;
    private final CredentialCrypto crypto;
    private final ObjectMapper objectMapper;

    public ScmService(ScmConfigRepository scmConfigRepository,
                      ProjectService projectService,
                      JobService jobService,
                      WorkflowClient workflowClient,
                      SubscriptionGate gate,
                      CredentialCrypto crypto,
                      ObjectMapper objectMapper) {
        this.scmConfigRepository = scmConfigRepository;
        this.projectService = projectService;
        this.jobService = jobService;
        this.workflowClient = workflowClient;
        this.gate = gate;
        this.crypto = crypto;
        this.objectMapper = objectMapper;
    }

    // ------ config ------

    @Transactional(readOnly = true)
    public Optional<ScmConfig> getConfig(String tenantId, Long projectId) {
        projectService.get(tenantId, projectId); // 404 if not the tenant's project
        return scmConfigRepository.findByProjectIdAndTenantId(projectId, tenantId);
    }

    @Transactional
    public ScmConfig saveConfig(String tenantId, String actor, String role, Long projectId,
                                String repoUrl, String branch, String basePath,
                                String username, String token, boolean clearToken) {
        if (!ApprovalService.ADMIN_ROLE.equals(role)) {
            throw CoreException.forbidden("scm_admin_only",
                    "Only an admin can change the SCM configuration");
        }
        if (clearToken && token != null && !token.isBlank()) {
            throw CoreException.badRequest("token_conflict",
                    "Send either a new token or clearToken, not both");
        }
        projectService.get(tenantId, projectId);
        validateRepoUrl(repoUrl);
        String cleanBranch = branch == null || branch.isBlank() ? "main" : branch.trim();
        if (!cleanBranch.matches("[\\w./-]{1,128}") || cleanBranch.contains("..")) {
            throw CoreException.badRequest("invalid_branch", "Branch name is not valid");
        }
        String cleanPath = sanitizeBasePath(basePath);

        ScmConfig config = scmConfigRepository.findByProjectIdAndTenantId(projectId, tenantId)
                .orElseGet(() -> {
                    ScmConfig fresh = new ScmConfig();
                    fresh.setProjectId(projectId);
                    fresh.setTenantId(tenantId);
                    return fresh;
                });
        config.setRepoUrl(repoUrl.trim());
        config.setBranch(cleanBranch);
        config.setBasePath(cleanPath);
        config.setUsername(username == null || username.isBlank() ? null : username.trim());
        if (clearToken) {
            config.setTokenEnc(null); // repo needs no credentials — clone anonymously
        } else if (token != null && !token.isBlank()) {
            config.setTokenEnc(crypto.encrypt(token.trim())); // omitted token keeps the old one
        }
        config.setUpdatedBy(actor);
        ScmConfig saved = scmConfigRepository.save(config);
        log.info("Tenant {} project {} SCM config saved by {} ({})",
                tenantId, projectId, actor, saved.getRepoUrl());
        return saved;
    }

    // ------ export ------

    public ExportResult export(String tenantId, String actor, String accessToken, Long projectId) {
        gate.requireActive(accessToken);
        ScmConfig config = requireConfig(tenantId, projectId);
        List<Job> jobs = jobService.list(tenantId, projectId);
        List<WorkflowClient.WorkflowView> workflows =
                workflowClient.listByProject(tenantId, projectId);

        return withClone(config, git -> {
            Path root = git.getRepository().getWorkTree().toPath();
            Path base = resolveBase(root, config.getBasePath());
            Path jobsDir = base.resolve("jobs");
            Path workflowsDir = base.resolve("workflows");
            // Replace both dirs wholesale so deletes and renames sync too.
            deleteRecursively(jobsDir);
            deleteRecursively(workflowsDir);
            Files.createDirectories(jobsDir);
            Files.createDirectories(workflowsDir);

            for (Job job : jobs) {
                ObjectNode doc = objectMapper.createObjectNode();
                doc.put("kind", "job");
                doc.put("name", job.getName());
                doc.put("group", job.getJobGroup());
                doc.put("description", job.getDescription());
                doc.put("schedule", job.getSchedule());
                doc.put("requiresApproval", job.isRequiresApproval());
                doc.set("definition", parseOrWrap(job.getDefinition()));
                writeDoc(jobsDir, job.getName(), job.getId(), doc);
            }
            for (WorkflowClient.WorkflowView workflow : workflows) {
                ObjectNode doc = objectMapper.createObjectNode();
                doc.put("kind", "workflow");
                doc.put("name", workflow.name());
                doc.set("definition", parseOrWrap(workflow.definition()));
                writeDoc(workflowsDir, workflow.name(), workflow.id(), doc);
            }

            git.add().addFilepattern(".").call();
            git.add().setUpdate(true).addFilepattern(".").call(); // stage deletions
            if (git.status().call().isClean()) {
                return new ExportResult(jobs.size(), workflows.size(), false, null);
            }
            RevCommit commit = git.commit()
                    .setAuthor("AutoOps", actor)
                    .setCommitter("AutoOps", actor)
                    .setMessage("AutoOps export: " + jobs.size() + " job(s), "
                            + workflows.size() + " workflow(s)")
                    .call();
            push(git, config);
            log.info("Tenant {} project {} exported to {} ({})",
                    tenantId, projectId, config.getRepoUrl(), commit.getName());
            return new ExportResult(jobs.size(), workflows.size(), true, commit.getName());
        });
    }

    // ------ import ------

    public ImportResult importFrom(String tenantId, String actor, String accessToken,
                                   Long projectId, ImportStrategy strategy) {
        gate.requireActive(accessToken);
        ScmConfig config = requireConfig(tenantId, projectId);
        List<Job> existingJobs = jobService.list(tenantId, projectId);
        List<WorkflowClient.WorkflowView> existingWorkflows =
                workflowClient.listByProject(tenantId, projectId);

        return withClone(config, git -> {
            Path root = git.getRepository().getWorkTree().toPath();
            Path base = resolveBase(root, config.getBasePath());
            if (!Files.isDirectory(base)) {
                throw CoreException.badRequest("scm_path_missing",
                        "The repo has no '" + config.getBasePath() + "' directory on branch "
                                + config.getBranch());
            }
            int created = 0;
            int updated = 0;
            int skipped = 0;
            List<String> errors = new ArrayList<>();
            for (Path file : listJsonFiles(base)) {
                String rel = base.relativize(file).toString();
                try {
                    JsonNode doc = objectMapper.readTree(Files.readString(file, StandardCharsets.UTF_8));
                    String kind = doc.path("kind").asText("");
                    String name = doc.path("name").asText("");
                    if (name.isBlank() || !(kind.equals("job") || kind.equals("workflow"))) {
                        errors.add(rel + ": missing kind/name");
                        continue;
                    }
                    String definition = doc.has("definition") && !doc.get("definition").isNull()
                            ? objectMapper.writeValueAsString(doc.get("definition")) : null;
                    if (kind.equals("job")) {
                        Job existing = existingJobs.stream()
                                .filter(j -> j.getName().equals(name)).findFirst().orElse(null);
                        if (existing == null) {
                            jobService.create(tenantId, actor, accessToken, projectId, name,
                                    textOrNull(doc, "group"), textOrNull(doc, "description"),
                                    definition, textOrNull(doc, "schedule"),
                                    doc.path("requiresApproval").asBoolean(false));
                            created++;
                        } else if (strategy == ImportStrategy.OVERWRITE) {
                            jobService.update(tenantId, accessToken, existing.getId(), name,
                                    textOrNull(doc, "group"), textOrNull(doc, "description"),
                                    definition, textOrNull(doc, "schedule"),
                                    doc.has("requiresApproval")
                                            ? doc.get("requiresApproval").asBoolean() : null);
                            updated++;
                        } else {
                            skipped++;
                        }
                    } else {
                        // Workflows are designed by the PROVIDER and rolled out; letting a
                        // tenant push one in from git would be a back door around that.
                        // Export still writes them out (read-only), so a round trip is
                        // lossless for jobs and honest about workflows.
                        errors.add(rel + ": workflows are managed by your provider and cannot"
                                + " be imported from source control");
                    }
                } catch (CoreException ex) {
                    errors.add(rel + ": " + ex.getMessage());
                } catch (Exception ex) {
                    errors.add(rel + ": not a valid definition file");
                }
            }
            log.info("Tenant {} project {} import from {}: {} created, {} updated, {} skipped, {} errors",
                    tenantId, projectId, config.getRepoUrl(), created, updated, skipped, errors.size());
            return new ImportResult(created, updated, skipped, errors);
        });
    }

    // ------ git plumbing ------

    private interface GitAction<T> {
        T run(Git git) throws Exception;
    }

    private <T> T withClone(ScmConfig config, GitAction<T> action) {
        Path tmp = null;
        try {
            tmp = Files.createTempDirectory("autoops-scm-");
            // Pick the branch to clone from what actually exists on the remote:
            // the configured one, else any head (dangling-HEAD repos clone fine
            // this way), else nothing (empty repo → unborn HEAD).
            List<org.eclipse.jgit.lib.Ref> heads = new ArrayList<>(Git.lsRemoteRepository()
                    .setRemote(config.getRepoUrl())
                    .setHeads(true)
                    .setCredentialsProvider(credentials(config))
                    .setTimeout(GIT_TIMEOUT_SECONDS)
                    .call());
            String wantedRef = Constants.R_HEADS + config.getBranch();
            String cloneBranch = heads.stream().anyMatch(r -> wantedRef.equals(r.getName()))
                    ? config.getBranch()
                    : heads.isEmpty() ? null
                    : org.eclipse.jgit.lib.Repository.shortenRefName(heads.get(0).getName());
            var cloneCmd = Git.cloneRepository()
                    .setURI(config.getRepoUrl())
                    .setDirectory(tmp.toFile())
                    .setCredentialsProvider(credentials(config))
                    .setTimeout(GIT_TIMEOUT_SECONDS);
            if (cloneBranch != null) {
                cloneCmd.setBranch(cloneBranch);
            }
            try (Git git = cloneCmd.call()) {
                checkoutBranch(git, config.getBranch());
                return action.run(git);
            }
        } catch (CoreException ex) {
            throw ex;
        } catch (TransportException ex) {
            throw CoreException.badRequest("scm_transport_failed",
                    "Could not reach the repository (check URL/credentials): " + ex.getMessage());
        } catch (Exception ex) {
            log.warn("SCM operation failed for {}: {}", config.getRepoUrl(), ex.toString());
            throw CoreException.badRequest("scm_failed", "Git operation failed: " + ex.getMessage());
        } finally {
            if (tmp != null) {
                deleteQuietly(tmp);
            }
        }
    }

    /** Existing remote branch → track it; new branch → create; empty repo → point unborn HEAD. */
    private void checkoutBranch(Git git, String branch) throws Exception {
        if (branch.equals(git.getRepository().getBranch())) {
            return;
        }
        boolean remoteHas = git.getRepository()
                .findRef(Constants.R_REMOTES + "origin/" + branch) != null;
        if (remoteHas) {
            git.checkout().setCreateBranch(true).setName(branch)
                    .setStartPoint("origin/" + branch).call();
        } else if (git.getRepository().resolve(Constants.HEAD) != null) {
            git.checkout().setCreateBranch(true).setName(branch).call();
        } else {
            // Empty repository: re-link the unborn HEAD to the wanted branch.
            git.getRepository().updateRef(Constants.HEAD)
                    .link(Constants.R_HEADS + branch);
        }
    }

    private void push(Git git, ScmConfig config) throws Exception {
        PushCommand push = git.push()
                .setRemote("origin")
                .setRefSpecs(new org.eclipse.jgit.transport.RefSpec(
                        Constants.HEAD + ":" + Constants.R_HEADS + config.getBranch()))
                .setCredentialsProvider(credentials(config))
                .setTimeout(GIT_TIMEOUT_SECONDS);
        for (PushResult result : push.call()) {
            for (RemoteRefUpdate update : result.getRemoteUpdates()) {
                if (update.getStatus() != RemoteRefUpdate.Status.OK
                        && update.getStatus() != RemoteRefUpdate.Status.UP_TO_DATE) {
                    throw CoreException.badRequest("scm_push_failed",
                            "Push rejected: " + update.getStatus()
                                    + (update.getMessage() != null ? " — " + update.getMessage() : ""));
                }
            }
        }
    }

    private CredentialsProvider credentials(ScmConfig config) {
        if (config.getTokenEnc() == null) {
            return null;
        }
        String user = config.getUsername() != null ? config.getUsername() : "token";
        return new UsernamePasswordCredentialsProvider(user, crypto.decrypt(config.getTokenEnc()));
    }

    // ------ helpers ------

    private ScmConfig requireConfig(String tenantId, Long projectId) {
        return getConfig(tenantId, projectId).orElseThrow(() ->
                CoreException.badRequest("scm_not_configured",
                        "Save the repository settings before syncing"));
    }

    static void validateRepoUrl(String repoUrl) {
        if (repoUrl == null || repoUrl.isBlank()) {
            throw CoreException.badRequest("invalid_repo_url", "Repository URL is required");
        }
        String url = repoUrl.trim().toLowerCase(Locale.ROOT);
        if (!(url.startsWith("https://") || url.startsWith("http://") || url.startsWith("file:"))) {
            throw CoreException.badRequest("invalid_repo_url",
                    "Only http(s) and file repository URLs are supported");
        }
    }

    static String sanitizeBasePath(String basePath) {
        if (basePath == null || basePath.isBlank()) {
            return "";
        }
        String clean = basePath.trim().replace('\\', '/');
        while (clean.startsWith("/")) {
            clean = clean.substring(1);
        }
        while (clean.endsWith("/")) {
            clean = clean.substring(0, clean.length() - 1);
        }
        if (clean.contains("..")) {
            throw CoreException.badRequest("invalid_path", "Path may not contain '..'");
        }
        return clean;
    }

    private static Path resolveBase(Path root, String basePath) {
        return basePath.isBlank() ? root : root.resolve(basePath);
    }

    private JsonNode parseOrWrap(String definition) {
        if (definition == null || definition.isBlank()) {
            return objectMapper.createObjectNode();
        }
        try {
            return objectMapper.readTree(definition);
        } catch (Exception ex) {
            return objectMapper.getNodeFactory().textNode(definition);
        }
    }

    private void writeDoc(Path dir, String name, Long id, ObjectNode doc) throws IOException {
        String slug = name.toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9]+", "-")
                .replaceAll("(^-|-$)", "");
        if (slug.isBlank()) {
            slug = "item";
        }
        Path file = dir.resolve(slug + "-" + id + ".json");
        Files.writeString(file,
                doc.toPrettyString() + System.lineSeparator(), StandardCharsets.UTF_8);
    }

    private static List<Path> listJsonFiles(Path base) throws IOException {
        try (Stream<Path> walk = Files.walk(base, 3)) {
            return walk.filter(p -> Files.isRegularFile(p)
                            && p.getFileName().toString().endsWith(".json")
                            && !p.toString().contains(".git"))
                    .sorted()
                    .toList();
        }
    }

    private static String textOrNull(JsonNode doc, String field) {
        JsonNode node = doc.get(field);
        return node == null || node.isNull() ? null : node.asText();
    }

    private static void deleteRecursively(Path dir) {
        if (Files.exists(dir)) {
            deleteQuietly(dir);
        }
    }

    private static void deleteQuietly(Path path) {
        try (Stream<Path> walk = Files.walk(path)) {
            walk.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
        } catch (IOException ignored) {
            // best-effort temp cleanup
        }
    }
}
