package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.client.EntitlementClient;
import com.intertec.autoops.core.client.SubscriptionInfoClient;
import com.intertec.autoops.core.client.SubscriptionInfoClient.PlanLimits;
import com.intertec.autoops.core.domain.Approval;
import com.intertec.autoops.core.domain.ApprovalStatus;
import com.intertec.autoops.core.domain.CloudConnection;
import com.intertec.autoops.core.domain.CloudPlatform;
import com.intertec.autoops.core.domain.ConnectionStatus;
import com.intertec.autoops.core.domain.GovernancePolicy;
import com.intertec.autoops.core.domain.GovernancePolicyMode;
import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.domain.Project;
import com.intertec.autoops.core.domain.Run;
import com.intertec.autoops.core.domain.RunStatus;
import com.intertec.autoops.core.domain.RunTargetType;
import com.intertec.autoops.core.domain.ScmConfig;
import com.intertec.autoops.core.client.WorkflowClient;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.ApprovalRepository;
import com.intertec.autoops.core.repo.CloudConnectionRepository;
import com.intertec.autoops.core.repo.ComplianceReportRepository;
import com.intertec.autoops.core.repo.GovernancePolicyRepository;
import com.intertec.autoops.core.repo.JobRepository;
import com.intertec.autoops.core.repo.ProjectRepository;
import com.intertec.autoops.core.repo.RunRepository;
import com.intertec.autoops.core.repo.ScmConfigRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.when;

/**
 * Governance: policy modes (defaults + stored overrides), violations
 * computed live from real data, and ENFORCED policies blocking manual
 * runs. Gate mocked at the EntitlementClient boundary like the siblings.
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Import({ProjectService.class, JobService.class,
        ApprovalSettingsService.class, GovernanceService.class, SubscriptionGate.class})
@Transactional(propagation = Propagation.NOT_SUPPORTED)
class GovernanceServiceTest {

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
    private static final String TOKEN = "test-access-token";
    private static final String ADMIN_ROLE = "ADMIN";
    private static final String CLIENT_ROLE = "CLIENT";
    private static final String STEPS = "{\"steps\":[{\"type\":\"script\",\"label\":\"Deploy\"}]}";

    private static final EntitlementClient.Decision OK =
            new EntitlementClient.Decision(true, "ok", null, null);

    @Autowired
    private GovernanceService governanceService;
    @Autowired
    private ProjectService projectService;
    @Autowired
    private JobService jobService;
    @Autowired
    private GovernancePolicyRepository policyRepository;
    @Autowired
    private ProjectRepository projectRepository;
    @Autowired
    private JobRepository jobRepository;
    @Autowired
    private RunRepository runRepository;
    @Autowired
    private ApprovalRepository approvalRepository;
    @Autowired
    private com.intertec.autoops.core.repo.ApprovalSettingRepository approvalSettingRepository;
    @Autowired
    private CloudConnectionRepository cloudConnectionRepository;
    @Autowired
    private ScmConfigRepository scmConfigRepository;
    @Autowired
    private ComplianceReportRepository complianceReportRepository;
    @Autowired
    private DataSource dataSource;
    @MockBean
    private EntitlementClient entitlementClient;
    @MockBean
    private WorkflowClient workflowClient;
    @MockBean
    private SubscriptionInfoClient subscriptionInfoClient;

    @TestConfiguration
    static class TestConfig {
        @Bean
        ObjectMapper objectMapper() {
            return new ObjectMapper();
        }
    }

    private Project project;
    private Job job;

    @BeforeEach
    void resetState() {
        policyRepository.deleteAll();
        complianceReportRepository.deleteAll();
        scmConfigRepository.deleteAll();
        cloudConnectionRepository.deleteAll();
        approvalRepository.deleteAll();
        approvalSettingRepository.deleteAll();
        runRepository.deleteAll();
        jobRepository.deleteAll();
        projectRepository.deleteAll();
        when(entitlementClient.checkActive(any())).thenReturn(OK);
        when(entitlementClient.checkQuota(any(), any(), anyLong())).thenReturn(OK);
        when(entitlementClient.checkFeature(any(), any())).thenReturn(OK);
        when(subscriptionInfoClient.planLimits(any(), any()))
                .thenReturn(new PlanLimits(null, null, null, null, null));
        project = projectService.create(TENANT, ADMIN, TOKEN, "Alpha", null);
        job = jobService.create(TENANT, ADMIN, TOKEN, project.getId(), "Deploy",
                null, null, STEPS, null, false);
    }

    @Test
    void defaultModesAndScmViolationInTheSummary() {
        GovernanceService.Summary summary = governanceService.summary(TENANT, TOKEN);

        Map<GovernancePolicy, GovernancePolicyMode> modes = governanceService.modes(TENANT);
        // Platform-default risky types exist → derived approval policy is enforced.
        assertEquals(GovernancePolicyMode.ENFORCED, modes.get(GovernancePolicy.RISKY_APPROVAL));
        assertEquals(GovernancePolicyMode.ENFORCED, modes.get(GovernancePolicy.CREDENTIAL_HYGIENE));
        assertEquals(GovernancePolicyMode.MONITOR, modes.get(GovernancePolicy.SCM_REQUIRED));
        assertEquals(2, summary.policiesEnforced());
        // No SCM config → one violation against the project.
        assertEquals(1, summary.openViolations());
        assertNull(summary.complianceScore(), "no reports yet");
        assertNull(summary.quotaUsage(), "no plan limits known");
    }

    @Test
    void quotaUsageIsTheWorstUtilizationAcrossLimits() {
        when(subscriptionInfoClient.planLimits(any(), any()))
                .thenReturn(new PlanLimits(90, 10, 20, 4, 5)); // 1 job of 4 = 25%

        GovernanceService.Summary summary = governanceService.summary(TENANT, TOKEN);

        assertEquals(25, summary.quotaUsage());
    }

    @Test
    void scmViolationClearsOnceConfigured() {
        ScmConfig config = new ScmConfig();
        config.setProjectId(project.getId());
        config.setTenantId(TENANT);
        config.setRepoUrl("https://git.acme.io/ops.git");
        scmConfigRepository.save(config);

        GovernanceService.Summary summary = governanceService.summary(TENANT, TOKEN);

        assertEquals(0, summary.openViolations());
    }

    @Test
    void scmRequiredEnforcedBlocksManualRunsUntilConfigured() {
        governanceService.setMode(TENANT, ADMIN, ADMIN_ROLE, TOKEN,
                "SCM_REQUIRED", "ENFORCED");

        CoreException ex = assertThrows(CoreException.class,
                () -> governanceService.assertJobRunAllowed(TENANT, job.getId()));
        assertEquals("policy_scm_required", ex.getError());

        ScmConfig config = new ScmConfig();
        config.setProjectId(project.getId());
        config.setTenantId(TENANT);
        config.setRepoUrl("https://git.acme.io/ops.git");
        scmConfigRepository.save(config);
        assertDoesNotThrow(() -> governanceService.assertJobRunAllowed(TENANT, job.getId()));
    }

    @Test
    void failureBudgetEnforcedBlocksRunsInFlakyProjects() {
        for (int i = 0; i < 3; i++) {
            saveRun(RunStatus.FAILED);
        }
        saveRun(RunStatus.SUCCEEDED);
        governanceService.setMode(TENANT, ADMIN, ADMIN_ROLE, TOKEN,
                "FAILURE_BUDGET", "ENFORCED");

        CoreException ex = assertThrows(CoreException.class,
                () -> governanceService.assertJobRunAllowed(TENANT, job.getId()));
        assertEquals("policy_failure_budget", ex.getError());

        // MONITOR mode reports the violation but never blocks.
        governanceService.setMode(TENANT, ADMIN, ADMIN_ROLE, TOKEN,
                "FAILURE_BUDGET", "MONITOR");
        assertDoesNotThrow(() -> governanceService.assertJobRunAllowed(TENANT, job.getId()));
        GovernanceService.Summary summary = governanceService.summary(TENANT, TOKEN);
        assertTrue(summary.policies().stream()
                .filter(p -> p.policy() == GovernancePolicy.FAILURE_BUDGET)
                .allMatch(p -> p.violations().size() == 1));
    }

    @Test
    void fewFinishedRunsAreNoiseNotAViolation() {
        saveRun(RunStatus.FAILED);
        saveRun(RunStatus.FAILED); // 100% failure but only 2 runs — below the floor

        GovernanceService.Summary summary = governanceService.summary(TENANT, TOKEN);

        assertTrue(summary.policies().stream()
                .filter(p -> p.policy() == GovernancePolicy.FAILURE_BUDGET)
                .allMatch(p -> p.violations().isEmpty()));
    }

    @Test
    void staleCredentialsAndStaleApprovalsAreViolations() throws Exception {
        CloudConnection stale = new CloudConnection();
        stale.setTenantId(TENANT);
        stale.setPlatform(CloudPlatform.AWS);
        stale.setName("legacy-aws");
        stale.setStatus(ConnectionStatus.DISCONNECTED);
        stale.setCredentialsEnc("v1:leftover");
        cloudConnectionRepository.save(stale);

        Approval pending = new Approval();
        pending.setTenantId(TENANT);
        pending.setProjectId(project.getId());
        pending.setTargetType(RunTargetType.JOB);
        pending.setTargetId(job.getId());
        pending.setTargetName("Deploy");
        pending.setRequestedBy("op@acme.io");
        pending.setStatus(ApprovalStatus.PENDING);
        pending = approvalRepository.save(pending);
        backdateApproval(pending.getId(), Instant.now().minus(Duration.ofDays(10)));

        GovernanceService.Summary summary = governanceService.summary(TENANT, TOKEN);

        assertTrue(summary.policies().stream()
                .filter(p -> p.policy() == GovernancePolicy.CREDENTIAL_HYGIENE)
                .allMatch(p -> p.violations().size() == 1));
        assertTrue(summary.policies().stream()
                .filter(p -> p.policy() == GovernancePolicy.APPROVAL_SLA)
                .allMatch(p -> p.violations().size() == 1
                        && p.violations().get(0).detail().contains("10 days")));
    }

    @Test
    void disabledPolicySkipsItsViolations() {
        governanceService.setMode(TENANT, ADMIN, ADMIN_ROLE, TOKEN,
                "SCM_REQUIRED", "DISABLED");

        GovernanceService.Summary summary = governanceService.summary(TENANT, TOKEN);

        assertEquals(0, summary.openViolations());
    }

    @Test
    void modeChangeValidationAndAccessControl() {
        CoreException role = assertThrows(CoreException.class, () -> governanceService
                .setMode(TENANT, "op@acme.io", CLIENT_ROLE, TOKEN, "SCM_REQUIRED", "ENFORCED"));
        assertEquals("governance_admin_only", role.getError());

        CoreException unknown = assertThrows(CoreException.class, () -> governanceService
                .setMode(TENANT, ADMIN, ADMIN_ROLE, TOKEN, "NOPE", "MONITOR"));
        assertEquals("invalid_policy", unknown.getError());

        CoreException fixed = assertThrows(CoreException.class, () -> governanceService
                .setMode(TENANT, ADMIN, ADMIN_ROLE, TOKEN, "CREDENTIAL_HYGIENE", "DISABLED"));
        assertEquals("policy_not_configurable", fixed.getError());

        CoreException sla = assertThrows(CoreException.class, () -> governanceService
                .setMode(TENANT, ADMIN, ADMIN_ROLE, TOKEN, "APPROVAL_SLA", "ENFORCED"));
        assertEquals("invalid_mode", sla.getError());
    }

    @Test
    void planWithoutTheFeatureCannotChangeModes() {
        when(entitlementClient.checkFeature(any(), any())).thenReturn(
                new EntitlementClient.Decision(false, "feature_not_in_plan", null, null));

        CoreException ex = assertThrows(CoreException.class, () -> governanceService
                .setMode(TENANT, ADMIN, ADMIN_ROLE, TOKEN, "SCM_REQUIRED", "ENFORCED"));

        assertEquals("feature_not_in_plan", ex.getError());
        assertEquals(0, policyRepository.count());
    }

    private void saveRun(RunStatus status) {
        Run run = new Run();
        run.setTenantId(TENANT);
        run.setProjectId(project.getId());
        run.setTargetType(RunTargetType.JOB);
        run.setTargetId(job.getId());
        run.setTargetName("Deploy");
        run.setStatus(status);
        runRepository.save(run);
    }

    /** created_at is DB-defaulted (insertable=false) — backdate with raw JDBC. */
    private void backdateApproval(Long id, Instant createdAt) throws Exception {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(
                     "update approvals set created_at = ? where id = ?")) {
            statement.setTimestamp(1, Timestamp.from(createdAt));
            statement.setLong(2, id);
            statement.executeUpdate();
        }
    }
}