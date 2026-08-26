package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.client.EntitlementClient;
import com.intertec.autoops.core.client.SubscriptionInfoClient;
import com.intertec.autoops.core.domain.CloudConnection;
import com.intertec.autoops.core.domain.CloudPlatform;
import com.intertec.autoops.core.domain.ComplianceFramework;
import com.intertec.autoops.core.domain.ComplianceReport;
import com.intertec.autoops.core.domain.ComplianceStatus;
import com.intertec.autoops.core.domain.ConnectionStatus;
import com.intertec.autoops.core.domain.Project;
import com.intertec.autoops.core.domain.Run;
import com.intertec.autoops.core.domain.RunStatus;
import com.intertec.autoops.core.domain.RunTargetType;
import com.intertec.autoops.core.domain.ScmConfig;
import com.intertec.autoops.core.client.WorkflowClient;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.ApprovalRepository;
import com.intertec.autoops.core.repo.ApprovalSettingRepository;
import com.intertec.autoops.core.repo.CloudConnectionRepository;
import com.intertec.autoops.core.repo.ComplianceReportRepository;
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
import org.springframework.http.HttpStatus;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.when;

/**
 * Compliance reports evaluate the project's REAL posture; findings are
 * snapshotted as JSON. Gate mocked at the EntitlementClient boundary like
 * the sibling suites.
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Import({ProjectService.class, JobService.class,
        ApprovalSettingsService.class, ComplianceService.class, SubscriptionGate.class})
@Transactional(propagation = Propagation.NOT_SUPPORTED)
class ComplianceServiceTest {

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
    private static final String STEPS = "{\"steps\":[{\"type\":\"script\",\"label\":\"Deploy\"}]}";

    private static final EntitlementClient.Decision OK =
            new EntitlementClient.Decision(true, "ok", null, null);
    private static final EntitlementClient.Decision NO_FEATURE =
            new EntitlementClient.Decision(false, "feature_not_in_plan", null, null);

    @Autowired
    private ComplianceService complianceService;
    @Autowired
    private ProjectService projectService;
    @Autowired
    private JobService jobService;
    @Autowired
    private ComplianceReportRepository reportRepository;
    @Autowired
    private ProjectRepository projectRepository;
    @Autowired
    private JobRepository jobRepository;
    @Autowired
    private RunRepository runRepository;
    @Autowired
    private ApprovalRepository approvalRepository;
    @Autowired
    private ApprovalSettingRepository approvalSettingRepository;
    @Autowired
    private CloudConnectionRepository cloudConnectionRepository;
    @Autowired
    private ScmConfigRepository scmConfigRepository;
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

    private final ObjectMapper mapper = new ObjectMapper();
    private Project project;

    @BeforeEach
    void resetState() {
        reportRepository.deleteAll();
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
        when(subscriptionInfoClient.historyDays(any(), any())).thenReturn(null);
        project = projectService.create(TENANT, ADMIN, TOKEN, "Alpha", null);
    }

    @Test
    void generateSnapshotsRealPostureAsJson() throws Exception {
        jobService.create(TENANT, ADMIN, TOKEN, project.getId(), "Prod Deploy",
                null, null, STEPS, null, true);

        ComplianceReport report = complianceService.generate(
                TENANT, ADMIN, TOKEN, project.getId(), "SOC 2");

        assertEquals(ComplianceFramework.SOC2, report.getFramework());
        assertEquals(ADMIN, report.getGeneratedBy());
        assertEquals(8, report.getControlsTotal());
        JsonNode content = mapper.readTree(report.getContent());
        assertEquals("SOC2", content.path("framework").asText());
        assertEquals("Alpha", content.path("project").path("name").asText());
        assertEquals(8, content.path("controls").size());
        // The gated job satisfies change authorization with real evidence.
        JsonNode change = findControl(content, "CC8.1");
        assertEquals("PASS", change.path("status").asText());
        assertTrue(change.path("evidence").asText().contains("1 of 1 job(s)"));
        // No SCM repo configured → version-control control fails honestly.
        assertEquals("FAIL", findControl(content, "A1.2").path("status").asText());
        assertEquals(ComplianceStatus.NON_COMPLIANT, report.getStatus());
        assertTrue(report.getFailed() >= 1);
    }

    @Test
    void cleanProjectWithScmIsCompliant() {
        ScmConfig scm = new ScmConfig();
        scm.setProjectId(project.getId());
        scm.setTenantId(TENANT);
        scm.setRepoUrl("https://git.acme.io/ops.git");
        scmConfigRepository.save(scm);

        ComplianceReport report = complianceService.generate(
                TENANT, ADMIN, TOKEN, project.getId(), "ISO 27001");

        assertEquals(ComplianceStatus.COMPLIANT, report.getStatus());
        assertEquals(0, report.getFailed());
        assertEquals(100, report.getScore());
    }

    @Test
    void failedRunsDegradeTheMonitoringControl() throws Exception {
        for (int i = 0; i < 3; i++) {
            saveRun(RunStatus.FAILED);
        }
        saveRun(RunStatus.SUCCEEDED);

        ComplianceReport report = complianceService.generate(
                TENANT, ADMIN, TOKEN, project.getId(), "SOC2");

        JsonNode monitoring = findControl(mapper.readTree(report.getContent()), "CC7.2");
        assertEquals("FAIL", monitoring.path("status").asText());
        assertTrue(monitoring.path("evidence").asText().contains("3 failed"));
        assertEquals(ComplianceStatus.NON_COMPLIANT, report.getStatus());
    }

    @Test
    void shortPlanRetentionFailsTheRetentionControl() throws Exception {
        when(subscriptionInfoClient.historyDays(any(), any())).thenReturn(30);

        ComplianceReport report = complianceService.generate(
                TENANT, ADMIN, TOKEN, project.getId(), "SOC2");

        JsonNode retention = findControl(mapper.readTree(report.getContent()), "CC4.1");
        assertEquals("FAIL", retention.path("status").asText());
        assertTrue(retention.path("evidence").asText().contains("30 days"));
    }

    @Test
    void lingeringCredentialsOnDisconnectedIntegrationFail() throws Exception {
        CloudConnection stale = new CloudConnection();
        stale.setTenantId(TENANT);
        stale.setPlatform(CloudPlatform.AWS);
        stale.setName("legacy-aws");
        stale.setStatus(ConnectionStatus.DISCONNECTED);
        stale.setCredentialsEnc("v1:leftover");
        cloudConnectionRepository.save(stale);

        ComplianceReport report = complianceService.generate(
                TENANT, ADMIN, TOKEN, project.getId(), "GDPR");

        JsonNode revocation = findControl(mapper.readTree(report.getContent()), "Art. 5(1)(e)");
        assertEquals("FAIL", revocation.path("status").asText());
        assertEquals(ComplianceStatus.NON_COMPLIANT, report.getStatus());
    }

    @Test
    void unknownFrameworkIsRejected() {
        CoreException ex = assertThrows(CoreException.class, () -> complianceService
                .generate(TENANT, ADMIN, TOKEN, project.getId(), "FEDRAMP"));
        assertEquals("invalid_framework", ex.getError());
        assertEquals(0, reportRepository.count());
    }

    @Test
    void frameworkParsingIsLenient() {
        assertEquals(ComplianceFramework.PCI_DSS,
                complianceService.generate(TENANT, ADMIN, TOKEN, project.getId(), "pci-dss")
                        .getFramework());
        assertEquals(ComplianceFramework.ISO_27001,
                complianceService.generate(TENANT, ADMIN, TOKEN, project.getId(), "ISO 27001")
                        .getFramework());
    }

    @Test
    void planWithoutTheFeatureIsDenied() {
        when(entitlementClient.checkFeature(any(), any())).thenReturn(NO_FEATURE);

        CoreException ex = assertThrows(CoreException.class, () -> complianceService
                .generate(TENANT, ADMIN, TOKEN, project.getId(), "SOC2"));

        assertEquals("feature_not_in_plan", ex.getError());
        assertEquals(HttpStatus.FORBIDDEN, ex.getStatus());
        assertEquals(0, reportRepository.count());
    }

    @Test
    void listAndGetAreTenantScoped() {
        ComplianceReport report = complianceService.generate(
                TENANT, ADMIN, TOKEN, project.getId(), "HIPAA");

        assertEquals(1, complianceService.list(TENANT, project.getId()).size());
        CoreException ex = assertThrows(CoreException.class,
                () -> complianceService.get("other-tenant", report.getId()));
        assertEquals("report_not_found", ex.getError());
    }

    @Test
    void renderHtmlProducesAStandaloneEvidenceDocument() {
        ComplianceReport report = complianceService.generate(
                TENANT, ADMIN, TOKEN, project.getId(), "SOC2");

        String html = complianceService.renderHtml(complianceService.get(TENANT, report.getId()));

        assertTrue(html.contains("SOC 2 Compliance Report"));
        assertTrue(html.contains("CC8.1"));
        assertTrue(html.contains("Alpha"));
        assertNotNull(report.getCreatedAt());
    }

    @Test
    void renderPdfProducesARealPdfDocument() {
        ComplianceReport report = complianceService.generate(
                TENANT, ADMIN, TOKEN, project.getId(), "SOC2");

        byte[] pdf = complianceService.renderPdf(complianceService.get(TENANT, report.getId()));

        assertTrue(pdf.length > 1000, "PDF should have real content");
        assertEquals("%PDF", new String(pdf, 0, 4, java.nio.charset.StandardCharsets.US_ASCII));
    }

    private void saveRun(RunStatus status) {
        Run run = new Run();
        run.setTenantId(TENANT);
        run.setProjectId(project.getId());
        run.setTargetType(RunTargetType.JOB);
        run.setTargetId(99L);
        run.setTargetName("Deploy");
        run.setStatus(status);
        runRepository.save(run);
    }

    private static JsonNode findControl(JsonNode content, String ref) {
        for (JsonNode control : content.path("controls")) {
            if (ref.equals(control.path("ref").asText())) {
                return control;
            }
        }
        throw new AssertionError("Control " + ref + " not found in report");
    }
}