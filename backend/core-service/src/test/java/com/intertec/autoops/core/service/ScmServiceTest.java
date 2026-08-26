package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.client.EntitlementClient;
import com.intertec.autoops.core.config.CoreProperties;
import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.domain.Project;
import com.intertec.autoops.core.client.WorkflowClient;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.JobRepository;
import com.intertec.autoops.core.repo.ProjectRepository;
import com.intertec.autoops.core.repo.ScmConfigRepository;
import org.eclipse.jgit.api.Git;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.when;

/**
 * Real git round-trips against a LOCAL BARE repository (file:// remote) —
 * no network, no credentials. Same H2 setup as the sibling service tests.
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Import({ProjectService.class, JobService.class,
        ScmService.class, SubscriptionGate.class, CredentialCrypto.class})
@Transactional(propagation = Propagation.NOT_SUPPORTED)
class ScmServiceTest {

    /** JobService now mirrors jobs onto the engine; this slice has no rundeck-service. */
    @MockBean
    private com.intertec.autoops.core.client.RundeckJobClient rundeckJobClient;

    /**
     * ProjectService now tells the execution engine when a project is created,
     * renamed or archived. Mocked because this slice has no rundeck-service.
     */
    @MockBean
    private com.intertec.autoops.core.client.RundeckProjectClient rundeckProjectClient;

    private static final String TENANT = "acme-corp-cafe0123";
    private static final String ADMIN = "admin@acme.io";
    private static final String ADMIN_ROLE = "ADMIN";
    private static final String CLIENT_ROLE = "CLIENT";
    private static final String TOKEN = "test-access-token";

    private static final EntitlementClient.Decision OK =
            new EntitlementClient.Decision(true, "ok", null, null);

    @Autowired
    private ProjectService projectService;
    @Autowired
    private JobService jobService;
    @Autowired
    private ScmService scmService;
    @Autowired
    private ProjectRepository projectRepository;
    @Autowired
    private JobRepository jobRepository;
    @Autowired
    private ScmConfigRepository scmConfigRepository;
    @MockBean
    private EntitlementClient entitlementClient;
    /**
     * Workflows live in workflow-service now, so SCM sync reads and writes
     * them over HTTP. This fake stands in for that service and keeps the
     * round trip (export writes what it holds; import writes back into it)
     * honest, which is the property these tests actually check.
     */
    @MockBean
    private WorkflowClient workflowClient;

    private final List<WorkflowClient.WorkflowView> remoteWorkflows = new ArrayList<>();

    @TestConfiguration
    static class TestConfig {
        @Bean
        ObjectMapper objectMapper() {
            return new ObjectMapper();
        }

        @Bean
        CoreProperties coreProperties() {
            return new CoreProperties(); // dev credential key is fine for tests
        }
    }

    @TempDir
    Path tempDir;

    private Project project;
    private String remoteUrl;

    @BeforeEach
    void resetState() throws Exception {
        scmConfigRepository.deleteAll();
        jobRepository.deleteAll();
        projectRepository.deleteAll();
        when(entitlementClient.checkActive(any())).thenReturn(OK);
        when(entitlementClient.checkQuota(any(), any(), anyLong())).thenReturn(OK);
        remoteWorkflows.clear();
        when(workflowClient.listByProject(any(), any()))
                .thenAnswer(inv -> List.copyOf(remoteWorkflows));
        when(workflowClient.create(any(), any(), any(), any(), any(), any()))
                .thenAnswer(inv -> {
                    WorkflowClient.WorkflowView created = new WorkflowClient.WorkflowView(
                            remoteWorkflows.size() + 1L, inv.getArgument(0), inv.getArgument(3),
                            inv.getArgument(4), inv.getArgument(5), 1, true);
                    remoteWorkflows.add(created);
                    return created;
                });
        project = projectService.create(TENANT, ADMIN, TOKEN, "Alpha", null);

        Path bare = tempDir.resolve("remote.git");
        Git.init().setBare(true).setInitialBranch("main").setDirectory(bare.toFile()).call().close();
        remoteUrl = bare.toUri().toString();
        scmService.saveConfig(TENANT, ADMIN, ADMIN_ROLE, project.getId(),
                remoteUrl, "main", "automation", null, null, false);
    }

    private Path cloneRemote() throws Exception {
        Path out = Files.createTempDirectory(tempDir, "verify-");
        Git.cloneRepository().setURI(remoteUrl).setDirectory(out.toFile()).call().close();
        return out;
    }

    @Test
    void exportWritesFilesCommitsAndPushes() throws Exception {
        jobService.create(TENANT, ADMIN, TOKEN, project.getId(), "Nightly Backup", "ops",
                "dumps the db", "{\"steps\":[{\"type\":\"script\",\"label\":\"dump\"}]}",
                null, true);
        remoteWorkflows.add(new WorkflowClient.WorkflowView(1L, TENANT, project.getId(),
                "Deploy", "{\"nodes\":[{\"type\":\"script\",\"label\":\"ship\"}]}", 1, true));

        ScmService.ExportResult result = scmService.export(TENANT, ADMIN, TOKEN, project.getId());

        assertTrue(result.pushed());
        assertNotNull(result.commitId());
        assertEquals(1, result.jobs());
        assertEquals(1, result.workflows());
        Path verify = cloneRemote();
        assertTrue(Files.exists(verify.resolve("automation/jobs")), "jobs dir exported");
        List<Path> jobFiles;
        try (var s = Files.list(verify.resolve("automation/jobs"))) {
            jobFiles = s.toList();
        }
        assertEquals(1, jobFiles.size());
        String content = Files.readString(jobFiles.get(0), StandardCharsets.UTF_8);
        assertTrue(content.contains("\"name\" : \"Nightly Backup\""));
        assertTrue(content.contains("\"requiresApproval\" : true"));
    }

    @Test
    void secondExportSyncsDeletions() throws Exception {
        Job keep = jobService.create(TENANT, ADMIN, TOKEN, project.getId(), "Keep", null, null,
                "{\"steps\":[]}", null, null);
        Job drop = jobService.create(TENANT, ADMIN, TOKEN, project.getId(), "Drop", null, null,
                "{\"steps\":[]}", null, null);
        scmService.export(TENANT, ADMIN, TOKEN, project.getId());

        jobService.delete(TENANT, TOKEN, drop.getId());
        ScmService.ExportResult second = scmService.export(TENANT, ADMIN, TOKEN, project.getId());

        assertTrue(second.pushed());
        Path verify = cloneRemote();
        try (var s = Files.list(verify.resolve("automation/jobs"))) {
            List<Path> files = s.toList();
            assertEquals(1, files.size(), "deleted job's file is gone from the repo");
            assertTrue(files.get(0).getFileName().toString().startsWith("keep-"));
        }
        assertNotNull(keep);
    }

    @Test
    void exportWithNoChangesDoesNotCommit() {
        jobService.create(TENANT, ADMIN, TOKEN, project.getId(), "Stable", null, null,
                "{\"steps\":[]}", null, null);
        ScmService.ExportResult first = scmService.export(TENANT, ADMIN, TOKEN, project.getId());
        ScmService.ExportResult second = scmService.export(TENANT, ADMIN, TOKEN, project.getId());

        assertTrue(first.pushed());
        assertTrue(!second.pushed(), "identical content produces no new commit");
    }

    @Test
    void importCreatesJobsButRefusesWorkflowsFromTheRepo() throws Exception {
        Path work = Files.createTempDirectory(tempDir, "seed-");
        try (Git git = Git.cloneRepository().setURI(remoteUrl).setDirectory(work.toFile()).call()) {
            Path jobs = work.resolve("automation/jobs");
            Path workflows = work.resolve("automation/workflows");
            Files.createDirectories(jobs);
            Files.createDirectories(workflows);
            Files.writeString(jobs.resolve("restore.json"), """
                    {"kind":"job","name":"Restore","group":"ops","schedule":"0 3 * * *",
                     "requiresApproval":true,
                     "definition":{"steps":[{"type":"script","label":"restore"}]}}
                    """);
            Files.writeString(workflows.resolve("pipeline.json"), """
                    {"kind":"workflow","name":"Pipeline",
                     "definition":{"nodes":[{"type":"script","label":"a"}]}}
                    """);
            git.getRepository().updateRef(org.eclipse.jgit.lib.Constants.HEAD)
                    .link("refs/heads/main");
            git.add().addFilepattern(".").call();
            git.commit().setAuthor("seed", "seed@test").setMessage("seed").call();
            git.push().setRemote("origin")
                    .setRefSpecs(new org.eclipse.jgit.transport.RefSpec("HEAD:refs/heads/main"))
                    .call();
        }

        ScmService.ImportResult result = scmService.importFrom(TENANT, ADMIN, TOKEN,
                project.getId(), ScmService.ImportStrategy.OVERWRITE);

        // The job imports. The workflow does NOT: workflows are designed by
        // the provider and rolled out, so accepting one from a tenant's git
        // repo would be a back door around that rule. It is reported as an
        // error rather than silently skipped.
        assertEquals(1, result.created());
        assertEquals(1, result.errors().size(), String.join("; ", result.errors()));
        assertTrue(result.errors().get(0).contains("managed by your provider"),
                "the refusal says why: " + result.errors().get(0));

        Job restored = jobService.list(TENANT, project.getId()).stream()
                .filter(j -> j.getName().equals("Restore")).findFirst().orElseThrow();
        assertTrue(restored.isRequiresApproval());
        assertEquals("0 3 * * *", restored.getSchedule());
        assertTrue(remoteWorkflows.isEmpty(), "nothing was written to workflow-service");
    }

    @Test
    void importStrategySkipKeepsLocalChanges() {
        jobService.create(TENANT, ADMIN, TOKEN, project.getId(), "Shared", "local", null,
                "{\"steps\":[]}", null, null);
        scmService.export(TENANT, ADMIN, TOKEN, project.getId());
        // Local edit after export; repo still holds the old copy.
        Job local = jobService.list(TENANT, project.getId()).get(0);
        jobService.update(TENANT, TOKEN, local.getId(), "Shared", "edited", null, null, null, null);

        ScmService.ImportResult skip = scmService.importFrom(TENANT, ADMIN, TOKEN,
                project.getId(), ScmService.ImportStrategy.SKIP);
        assertEquals(1, skip.skipped());
        assertEquals("edited", jobService.list(TENANT, project.getId()).get(0).getJobGroup());

        ScmService.ImportResult overwrite = scmService.importFrom(TENANT, ADMIN, TOKEN,
                project.getId(), ScmService.ImportStrategy.OVERWRITE);
        assertEquals(1, overwrite.updated());
        assertEquals("local", jobService.list(TENANT, project.getId()).get(0).getJobGroup(),
                "repo wins under OVERWRITE");
    }

    @Test
    void configValidationAndRoles() {
        CoreException role = assertThrows(CoreException.class, () -> scmService.saveConfig(
                TENANT, "op@acme.io", CLIENT_ROLE, project.getId(),
                remoteUrl, "main", "", null, null, false));
        assertEquals("scm_admin_only", role.getError());

        CoreException url = assertThrows(CoreException.class, () -> scmService.saveConfig(
                TENANT, ADMIN, ADMIN_ROLE, project.getId(),
                "ssh://git@host/repo.git", "main", "", null, null, false));
        assertEquals("invalid_repo_url", url.getError());

        CoreException path = assertThrows(CoreException.class, () -> scmService.saveConfig(
                TENANT, ADMIN, ADMIN_ROLE, project.getId(),
                remoteUrl, "main", "../escape", null, null, false));
        assertEquals("invalid_path", path.getError());
    }

    @Test
    void blankTokenKeepsTheStoredOneAndClearTokenDropsIt() {
        scmService.saveConfig(TENANT, ADMIN, ADMIN_ROLE, project.getId(),
                remoteUrl, "main", "automation", "git", "ghp_secret", false);
        assertNotNull(scmConfigRepository.findByProjectIdAndTenantId(project.getId(), TENANT)
                .orElseThrow().getTokenEnc());

        // Blank token on a later save keeps the stored one.
        scmService.saveConfig(TENANT, ADMIN, ADMIN_ROLE, project.getId(),
                remoteUrl, "main", "automation", "git", null, false);
        assertNotNull(scmConfigRepository.findByProjectIdAndTenantId(project.getId(), TENANT)
                .orElseThrow().getTokenEnc());

        // clearToken is the explicit way out — needed when pointing at a repo
        // the stored token was never issued for.
        scmService.saveConfig(TENANT, ADMIN, ADMIN_ROLE, project.getId(),
                remoteUrl, "main", "automation", null, null, true);
        assertNull(scmConfigRepository.findByProjectIdAndTenantId(project.getId(), TENANT)
                .orElseThrow().getTokenEnc());
    }

    @Test
    void clearTokenWithANewTokenIsRejected() {
        CoreException ex = assertThrows(CoreException.class, () -> scmService.saveConfig(
                TENANT, ADMIN, ADMIN_ROLE, project.getId(),
                remoteUrl, "main", "automation", "git", "ghp_secret", true));
        assertEquals("token_conflict", ex.getError());
    }

    @Test
    void exportStillWorksAfterClearingTheTokenOnAnAnonymousRemote() {
        jobService.create(TENANT, ADMIN, TOKEN, project.getId(), "Anon", null, null,
                "{\"steps\":[]}", null, null);
        scmService.saveConfig(TENANT, ADMIN, ADMIN_ROLE, project.getId(),
                remoteUrl, "main", "automation", null, null, true);

        ScmService.ExportResult result = scmService.export(TENANT, ADMIN, TOKEN, project.getId());

        assertTrue(result.pushed());
        assertEquals(1, result.jobs());
    }

    @Test
    void exportWithoutConfigFails() {
        Project other = projectService.create(TENANT, ADMIN, TOKEN, "Beta", null);
        CoreException ex = assertThrows(CoreException.class, () ->
                scmService.export(TENANT, ADMIN, TOKEN, other.getId()));
        assertEquals("scm_not_configured", ex.getError());
    }
}
