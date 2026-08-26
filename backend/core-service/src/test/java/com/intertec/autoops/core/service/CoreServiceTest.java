package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.client.EntitlementClient;
import com.intertec.autoops.core.domain.ConnectionStatus;
import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.domain.Project;
import com.intertec.autoops.core.domain.ProjectStatus;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.CloudConnectionRepository;
import com.intertec.autoops.core.repo.JobRepository;
import com.intertec.autoops.core.repo.ProjectRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
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
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Project/workflow lifecycle against H2 with real commit semantics, with the
 * subscription gate mocked at the EntitlementClient boundary — every denial
 * reason subscription-service can return is exercised here.
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Import({ProjectService.class, JobService.class,
        CloudConnectionService.class, CredentialCrypto.class, SubscriptionGate.class,
        CloudAccountRegistry.class})
@Transactional(propagation = Propagation.NOT_SUPPORTED)
class CoreServiceTest {

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
    private static final String OTHER_TENANT = "rival-inc-beef4567";
    private static final String ACTOR = "admin@acme.io";
    private static final String TOKEN = "test-access-token";

    private static final EntitlementClient.Decision OK =
            new EntitlementClient.Decision(true, "ok", null, null);

    @Autowired
    private ProjectService projectService;
    @Autowired
    private JobService jobService;
    @Autowired
    private CloudConnectionService cloudConnectionService;
    @Autowired
    private ProjectRepository projectRepository;
    @Autowired
    private JobRepository jobRepository;
    @Autowired
    private CloudConnectionRepository cloudConnectionRepository;
    @Autowired
    private com.intertec.autoops.core.repo.CloudAccountClaimRepository cloudAccountClaimRepository;
    @MockBean
    private EntitlementClient entitlementClient;
    @MockBean
    private com.intertec.autoops.core.client.VerificationClient verificationClient;

    @TestConfiguration
    static class TestConfig {
        @Bean
        ObjectMapper objectMapper() {
            return new ObjectMapper();
        }

        @Bean
        com.intertec.autoops.core.config.CoreProperties coreProperties() {
            return new com.intertec.autoops.core.config.CoreProperties();
        }
    }

    @BeforeEach
    void resetState() {
        jobRepository.deleteAll();
        cloudAccountClaimRepository.deleteAll();
        cloudConnectionRepository.deleteAll();
        projectRepository.deleteAll();
        when(entitlementClient.checkActive(any())).thenReturn(OK);
        when(entitlementClient.checkQuota(any(), any(), anyLong())).thenReturn(OK);
    }

    // ------ projects ------

    @Test
    void createProjectAsksTheQuotaGateWithTheActiveCount() {
        projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        projectService.create(TENANT, ACTOR, TOKEN, "Beta", "second");

        ArgumentCaptor<Long> current = ArgumentCaptor.forClass(Long.class);
        verify(entitlementClient, org.mockito.Mockito.times(2))
                .checkQuota(eq(TOKEN), eq("MAX_PROJECTS"), current.capture());
        assertEquals(java.util.List.of(0L, 1L), current.getAllValues());
    }

    @Test
    void createProjectDeniedAtQuota() {
        when(entitlementClient.checkQuota(any(), eq("MAX_PROJECTS"), anyLong()))
                .thenReturn(new EntitlementClient.Decision(false, "quota_exceeded", 3, 0L));

        CoreException ex = assertThrows(CoreException.class,
                () -> projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null));
        assertEquals("quota_exceeded", ex.getError());
        assertEquals(HttpStatus.FORBIDDEN, ex.getStatus());
        assertTrue(ex.getMessage().contains("3"), "message carries the plan max for the UI");
    }

    @Test
    void mutationDeniedWhenSubscriptionExpired() {
        Project project = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        when(entitlementClient.checkActive(any()))
                .thenReturn(new EntitlementClient.Decision(false, "trial_expired", null, null));

        CoreException ex = assertThrows(CoreException.class,
                () -> projectService.archive(TENANT, TOKEN, project.getId()));
        assertEquals("trial_expired", ex.getError());
        assertEquals(HttpStatus.FORBIDDEN, ex.getStatus());
    }

    @Test
    void readsAreNeverGated() {
        Project project = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        org.mockito.Mockito.clearInvocations(entitlementClient);

        projectService.list(TENANT);
        projectService.get(TENANT, project.getId());

        verify(entitlementClient, never()).checkActive(any());
        verify(entitlementClient, never()).checkQuota(any(), any(), anyLong());
    }

    @Test
    void archiveFreesTheSlotAndRestoreRechecksQuota() {
        Project project = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        projectService.archive(TENANT, TOKEN, project.getId());
        assertEquals(0, projectRepository.countByTenantIdAndStatus(TENANT, ProjectStatus.ACTIVE));

        when(entitlementClient.checkQuota(any(), eq("MAX_PROJECTS"), anyLong()))
                .thenReturn(new EntitlementClient.Decision(false, "quota_exceeded", 3, 0L));
        CoreException ex = assertThrows(CoreException.class,
                () -> projectService.restore(TENANT, TOKEN, project.getId()));
        assertEquals("quota_exceeded", ex.getError());
    }

    @Test
    void tenantsAreIsolated() {
        Project project = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);

        CoreException ex = assertThrows(CoreException.class,
                () -> projectService.get(OTHER_TENANT, project.getId()));
        assertEquals("project_not_found", ex.getError());
    }

    // ------ workflows ------
    // Moved to workflow-service (WorkflowServiceTest): node counting,
    // MAX_NODES on definition changes, and the shared MAX_AUTOMATIONS budget
    // are that service's rules now. What stays here is everything workflows
    // are still ENTANGLED with — runs, approvals, SCM, compliance — which the
    // other test classes cover against a mocked WorkflowClient.

    // ------ jobs ------

    @Test
    void jobCreationIsQuotaGatedAndCountsSteps() {
        Project project = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        Job job = jobService.create(TENANT, ACTOR, TOKEN, project.getId(), "Nightly Backup",
                "database/cleanup", "Snapshots the DB",
                "{\"steps\":[{\"type\":\"script\"},{\"type\":\"awslambda\"}]}", "0 2 * * *");

        assertEquals(2, job.getStepCount());
        verify(entitlementClient).checkQuota(eq(TOKEN), eq("MAX_JOBS"), eq(0L));

        when(entitlementClient.checkQuota(any(), eq("MAX_JOBS"), anyLong()))
                .thenReturn(new EntitlementClient.Decision(false, "quota_exceeded", 5, 0L));
        CoreException ex = assertThrows(CoreException.class,
                () -> jobService.create(TENANT, ACTOR, TOKEN, project.getId(), "Another",
                        null, null, null, null));
        assertEquals("quota_exceeded", ex.getError());
    }

    @Test
    void deletingAJobFreesItsSlot() {
        Project project = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        Job job = jobService.create(TENANT, ACTOR, TOKEN, project.getId(), "Backup",
                null, null, null, null);
        jobService.delete(TENANT, TOKEN, job.getId());
        org.mockito.Mockito.clearInvocations(entitlementClient);

        jobService.create(TENANT, ACTOR, TOKEN, project.getId(), "Backup again",
                null, null, null, null);
        verify(entitlementClient).checkQuota(eq(TOKEN), eq("MAX_JOBS"), eq(0L));
    }

    // ------ cloud connections ------

    @Test
    void cloudConnectionIsQuotaGated() {
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Production", null);
        verify(entitlementClient).checkQuota(eq(TOKEN), eq("MAX_CLOUD_INTEGRATIONS"), eq(0L));

        when(entitlementClient.checkQuota(any(), eq("MAX_CLOUD_INTEGRATIONS"), anyLong()))
                .thenReturn(new EntitlementClient.Decision(false, "quota_exceeded", 2, 0L));
        CoreException ex = assertThrows(CoreException.class,
                () -> cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "gcp", "GCP Dev", null));
        assertEquals("quota_exceeded", ex.getError());
    }

    @Test
    void disconnectFreesTheSlotAndDropsCredentials() {
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "azure",
                "Azure Prod", "{\"clientId\":\"c\"}");
        cloudConnectionService.disconnect(TENANT, TOKEN, connection.getId());

        assertEquals(0, cloudConnectionRepository.countByTenantIdAndStatus(TENANT,
                ConnectionStatus.CONNECTED));
        var kept = cloudConnectionRepository.findByTenantIdOrderByCreatedAtDesc(TENANT).get(0);
        assertEquals(null, kept.getCredentialsEnc(),
                "disconnected integrations must not keep executable secrets");
    }

    @Test
    void unknownCloudPlatformIsRejected() {
        CoreException ex = assertThrows(CoreException.class,
                () -> cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "digitalocean", "DO", null));
        assertEquals("unknown_platform", ex.getError());
    }

    @Test
    void reconnectingByNameRevivesTheDisconnectedIntegration() {
        // uq_cloud_tenant_name spans (tenant, name) whatever the status, so
        // re-adding under a disconnected row's name used to reach the database
        // and come back a 500. It is a reconnect, and it keeps the same row.
        var original = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws",
                "AWS Production", "{\"accessKeyId\":\"OLD\"}");
        cloudConnectionService.disconnect(TENANT, TOKEN, original.getId());

        var reconnected = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws",
                "AWS Production", "{\"accessKeyId\":\"NEW\"}");

        assertEquals(original.getId(), reconnected.getId(), "history stays on one row");
        assertEquals(ConnectionStatus.CONNECTED, reconnected.getStatus());
        assertEquals(1, cloudConnectionRepository.findByTenantIdOrderByCreatedAtDesc(TENANT).size(),
                "no duplicate row is created");
        var bundle = cloudConnectionService.resolveForStep(TENANT, null, null,
                java.util.Set.of(com.intertec.autoops.core.domain.CloudPlatform.AWS))
                .orElseThrow();
        assertEquals("NEW", bundle.data().path("accessKeyId").asText());
    }

    @Test
    void reconnectingClearsTheOldVerificationBadge() {
        var original = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws",
                "AWS Production", "{\"accessKeyId\":\"OLD\"}");
        // Stand in for a past successful verify of the OLD credentials.
        var stored = cloudConnectionRepository.findById(original.getId()).orElseThrow();
        stored.setLastVerifiedOk(true);
        stored.setVerifiedAccountName("Some Account");
        cloudConnectionRepository.save(stored);
        cloudConnectionService.disconnect(TENANT, TOKEN, original.getId());

        var reconnected = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws",
                "AWS Production", "{\"accessKeyId\":\"NEW\"}");

        assertEquals(null, reconnected.getLastVerifiedOk(),
                "the UI must not vouch for credentials that no longer exist");
        assertEquals(null, reconnected.getVerifiedAccountName());
    }

    @Test
    void aNameHeldByADisconnectedIntegrationOfAnotherPlatformIsRefusedCleanly() {
        var original = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "Shared name",
                null);
        cloudConnectionService.disconnect(TENANT, TOKEN, original.getId());

        // Reviving it as AZURE would silently change what the name means to
        // every step bound to it — 409 with a way out, never a 500.
        CoreException ex = assertThrows(CoreException.class, () ->
                cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "azure", "Shared name", null));
        assertEquals("connection_name_taken", ex.getError());
        assertEquals(HttpStatus.CONFLICT, ex.getStatus());
    }

    @Test
    void reconnectingStillCostsAQuotaSlot() {
        var original = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Production",
                null);
        cloudConnectionService.disconnect(TENANT, TOKEN, original.getId());
        org.mockito.Mockito.clearInvocations(entitlementClient);

        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Production", null);

        // The row was not CONNECTED while it was down, so the count excludes it.
        verify(entitlementClient).checkQuota(eq(TOKEN), eq("MAX_CLOUD_INTEGRATIONS"), eq(0L));
    }

    @Test
    void credentialsAreEncryptedAtRestAndResolvableForSteps() {
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "kubernetes", "Prod Cluster",
                "{\"kubeconfig\":\"apiVersion: v1\\nkind: Config\"}");

        var stored = cloudConnectionRepository.findByTenantIdOrderByCreatedAtDesc(TENANT).get(0);
        assertTrue(stored.getCredentialsEnc() != null
                        && !stored.getCredentialsEnc().contains("kubeconfig"),
                "plaintext must never hit the database");

        var bundle = cloudConnectionService.resolveForStep(TENANT, null, null,
                java.util.Set.of(com.intertec.autoops.core.domain.CloudPlatform.KUBERNETES))
                .orElseThrow();
        assertTrue(bundle.data().path("kubeconfig").asText().startsWith("apiVersion"));

        // Other tenants must never resolve this connection.
        assertTrue(cloudConnectionService.resolveForStep(OTHER_TENANT, null, null,
                java.util.Set.of(com.intertec.autoops.core.domain.CloudPlatform.KUBERNETES))
                .isEmpty());
    }

    @Test
    void verifyPersistsTheProviderOutcomeOnTheConnection() {
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws",
                "AWS Prod", "{\"accessId\":\"AKIA\",\"secret\":\"s\"}");
        when(verificationClient.verify(eq(TENANT), eq("AWS"), any())).thenReturn(
                new com.intertec.autoops.core.client.VerificationClient.VerifyResult(
                        true, true, "Authenticated with AWS as arn:aws:iam::123:user/x",
                        null, null, java.util.Map.of()));

        var outcome = cloudConnectionService.verify(TENANT, ACTOR, TOKEN, connection.getId());
        assertTrue(outcome.verified());

        var stored = cloudConnectionRepository.findByIdAndTenantId(connection.getId(), TENANT)
                .orElseThrow();
        assertEquals(Boolean.TRUE, stored.getLastVerifiedOk());
        assertTrue(stored.getLastVerifiedMessage().contains("arn:aws:iam::123"));
        assertTrue(stored.getLastVerifiedAt() != null);
    }

    @Test
    void verifyOfAnUnsupportedPlatformStaysNeutralNotRed() {
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "huawei",
                "HW Cloud", "{\"ak\":\"x\"}");
        when(verificationClient.verify(eq(TENANT), eq("HUAWEI"), any())).thenReturn(
                new com.intertec.autoops.core.client.VerificationClient.VerifyResult(
                        false, false, "No live verification for HUAWEI yet", null, null, java.util.Map.of()));

        var outcome = cloudConnectionService.verify(TENANT, ACTOR, TOKEN, connection.getId());
        assertEquals(false, outcome.supported());

        var stored = cloudConnectionRepository.findByIdAndTenantId(connection.getId(), TENANT)
                .orElseThrow();
        assertEquals(null, stored.getLastVerifiedOk(),
                "unsupported platforms must not show as failed");
    }

    @Test
    void verifyWithoutStoredCredentialsIsAConfigError() {
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws",
                "No Creds", null);
        CoreException ex = assertThrows(CoreException.class,
                () -> cloudConnectionService.verify(TENANT, ACTOR, TOKEN, connection.getId()));
        assertEquals("missing_credentials", ex.getError());
    }

    @Test
    void invalidCredentialJsonIsRejected() {
        CoreException ex = assertThrows(CoreException.class,
                () -> cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws",
                        "Bad Creds", "not-json"));
        assertEquals("invalid_credentials", ex.getError());
    }

    @Test
    void describeExposesAccountAndRegionButNeverTheSecret() {
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Prod",
                "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"wJalrXUtnFEMI\","
                        + "\"region\":\"eu-central-1\"}");

        var info = cloudConnectionService.describe(connection);
        assertEquals("eu-central-1", info.region());
        assertTrue(info.accountId().startsWith("AKIA") && info.accountId().endsWith("MPLE"),
                "the access key id is masked, not hidden entirely");
        assertTrue(!info.accountId().contains("IOSFODNN7EX"), "the middle must be masked");
        assertTrue(!info.toString().contains("wJalrXUtnFEMI"),
                "the secret key must never be exposed for display");
    }

    @Test
    void awsAccountNumberComesFromTheVerifiedArnWhenKnown() {
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Prod",
                "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"s\",\"region\":\"us-east-1\"}");
        when(verificationClient.verify(eq(TENANT), eq("AWS"), any())).thenReturn(
                new com.intertec.autoops.core.client.VerificationClient.VerifyResult(
                        true, true, "Authenticated with AWS as arn:aws:iam::123456789012:user/x",
                        null, null, java.util.Map.of()));
        cloudConnectionService.verify(TENANT, ACTOR, TOKEN, connection.getId());

        var stored = cloudConnectionRepository.findByIdAndTenantId(connection.getId(), TENANT)
                .orElseThrow();
        assertEquals("123456789012", cloudConnectionService.describe(stored).accountId(),
                "the real account number beats the local key once the provider confirms it");
    }

    // ------ one cloud account, one tenant ------

    /** Distinct kubeconfigs pointed at the same private endpoint. */
    private static String kubeconfig(String server, String token) {
        return "{\"kubeconfig\":\"apiVersion: v1\\nclusters:\\n- cluster:\\n    server: " + server
                + "\\nusers:\\n- user:\\n    token: " + token + "\\n\"}";
    }

    @Test
    void leakedCredentialsCannotBeConnectedBySecondTenant() {
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Prod",
                "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"wJalrXUtnFEMI\"}");

        // The thief pastes the very same key into their own tenant.
        CoreException ex = assertThrows(CoreException.class,
                () -> cloudConnectionService.connect(OTHER_TENANT, "thief@rival.io", TOKEN,
                        "aws", "Borrowed", "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\","
                                + "\"secret\":\"wJalrXUtnFEMI\"}"));
        assertEquals("cloud_account_taken", ex.getError());
        assertEquals(HttpStatus.CONFLICT, ex.getStatus());
        assertTrue(!ex.getMessage().contains(TENANT),
                "the refusal must not disclose which tenant holds the account");
        assertTrue(cloudConnectionRepository.findByTenantIdOrderByCreatedAtDesc(OTHER_TENANT)
                .isEmpty(), "the refused connection must not be stored");
    }

    @Test
    void aRefusedCredentialIsNeverSentToTheProvider() {
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Prod",
                "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"s\"}");

        CoreException ex = assertThrows(CoreException.class,
                () -> cloudConnectionService.verifyCredentials(OTHER_TENANT, "thief@rival.io",
                        TOKEN, "aws", "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"s\"}"));
        assertEquals("cloud_account_taken", ex.getError());
        verify(verificationClient, never()).verify(any(), any(), any());
    }

    @Test
    void oneTenantMayHoldTheSameAccountOnSeveralConnections() {
        var alpha = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        var beta = projectService.create(TENANT, ACTOR, TOKEN, "Beta", null);
        String credentials = "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"s\"}";

        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Alpha",
                credentials, alpha.getId());
        // One AWS account serving two projects is a normal setup, not a leak.
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Beta",
                credentials, beta.getId());

        assertEquals(2, cloudConnectionRepository.countByTenantIdAndStatus(TENANT,
                ConnectionStatus.CONNECTED));
    }

    @Test
    void disconnectingHandsTheAccountBack() {
        String credentials = "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"s\"}";
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws",
                "AWS Prod", credentials);
        cloudConnectionService.disconnect(TENANT, TOKEN, connection.getId());

        // A real handover — the account moves to whoever holds it next.
        cloudConnectionService.connect(OTHER_TENANT, ACTOR, TOKEN, "aws", "AWS Prod",
                credentials);
        assertEquals(1, cloudConnectionRepository.countByTenantIdAndStatus(OTHER_TENANT,
                ConnectionStatus.CONNECTED));
    }

    @Test
    void aFreshKeyPairForAnAlreadyClaimedAccountIsQuarantined() {
        var owned = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Prod",
                "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"s\"}");
        when(verificationClient.verify(any(), eq("AWS"), any())).thenReturn(
                new com.intertec.autoops.core.client.VerificationClient.VerifyResult(
                        true, true, "Authenticated with AWS", "123456789012", "acme",
                        java.util.Map.of()));
        cloudConnectionService.verify(TENANT, ACTOR, TOKEN, owned.getId());

        // A different IAM user in the SAME account gets past the credential
        // check — only the provider can reveal that it is the same account.
        var intruder = cloudConnectionService.connect(OTHER_TENANT, "thief@rival.io", TOKEN,
                "aws", "Borrowed", "{\"accessId\":\"AKIAI44QH8DHBEXAMPLE\",\"secret\":\"x\"}");
        CoreException ex = assertThrows(CoreException.class,
                () -> cloudConnectionService.verify(OTHER_TENANT, "thief@rival.io", TOKEN,
                        intruder.getId()));
        assertEquals("cloud_account_taken", ex.getError());

        var stored = cloudConnectionRepository.findByIdAndTenantId(intruder.getId(), OTHER_TENANT)
                .orElseThrow();
        assertEquals(null, stored.getCredentialsEnc(),
                "credentials proven to reach another tenant's account must be destroyed");
        assertEquals(ConnectionStatus.DISCONNECTED, stored.getStatus());
        assertTrue(stored.getLastVerifiedMessage().contains("another AutoOps tenant"),
                "the integration says why it was cut off");
        assertTrue(cloudAccountClaimRepository.findByTenantId(OTHER_TENANT).isEmpty(),
                "a quarantined connection keeps no claims");
    }

    @Test
    void claimsStoreAKeyedHashNeverTheIdentifierItself() {
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Prod",
                "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"s\"}");

        var claims = cloudAccountClaimRepository.findByTenantId(TENANT);
        assertEquals(1, claims.size());
        String fingerprint = claims.get(0).getFingerprint();
        assertTrue(fingerprint.matches("[0-9a-f]{64}"), "a hex HMAC digest");
        assertTrue(!fingerprint.toUpperCase(java.util.Locale.ROOT).contains("AKIA"),
                "the access key id itself must never be stored");
    }

    @Test
    void privateClusterEndpointsAreSharedGroundNotAnIdentity() {
        // Two unrelated customers, both running a cluster on 10.0.0.1. Blocking
        // the second one would be a false match, so the endpoint is not claimed.
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "kubernetes", "Ours",
                kubeconfig("https://10.0.0.1:6443", "token-for-acme-cluster"));
        cloudConnectionService.connect(OTHER_TENANT, ACTOR, TOKEN, "kubernetes", "Theirs",
                kubeconfig("https://10.0.0.1:6443", "token-for-rival-cluster"));

        assertEquals(1, cloudConnectionRepository.countByTenantIdAndStatus(OTHER_TENANT,
                ConnectionStatus.CONNECTED));
    }

    @Test
    void aPublicClusterEndpointIsOneTenantsAccount() {
        String server = "https://ABC123.gr7.eu-central-1.eks.amazonaws.com";
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "kubernetes", "Ours",
                kubeconfig(server, "token-for-acme-cluster"));

        CoreException ex = assertThrows(CoreException.class,
                () -> cloudConnectionService.connect(OTHER_TENANT, ACTOR, TOKEN, "kubernetes",
                        "Theirs", kubeconfig(server, "a-different-stolen-token")));
        assertEquals("cloud_account_taken", ex.getError());
    }

    @Test
    void rekeyingCannotSmuggleInAnotherTenantsCredentials() {
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Prod",
                "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"s\"}");
        var intruder = cloudConnectionService.connect(OTHER_TENANT, "thief@rival.io", TOKEN,
                "aws", "Borrowed", null);

        CoreException ex = assertThrows(CoreException.class,
                () -> cloudConnectionService.setCredentials(OTHER_TENANT, "thief@rival.io",
                        TOKEN, intruder.getId(),
                        "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"s\"}"));
        assertEquals("cloud_account_taken", ex.getError());
    }

    @Test
    void rekeyingReleasesTheCredentialItReplaced() {
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws", "AWS Prod",
                "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"s\"}");
        cloudConnectionService.setCredentials(TENANT, ACTOR, TOKEN, connection.getId(),
                "{\"accessId\":\"AKIAI44QH8DHBEXAMPLE\",\"secret\":\"s2\"}");

        assertEquals(1, cloudAccountClaimRepository.findByTenantId(TENANT).size(),
                "the retired key must not keep holding a claim");
        // The retired key is free again — it is no longer in use anywhere.
        cloudConnectionService.connect(OTHER_TENANT, ACTOR, TOKEN, "aws", "Theirs",
                "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"s\"}");
    }

    // ------ execution-time project scoping ------

    private static final java.util.Set<com.intertec.autoops.core.domain.CloudPlatform> K8S =
            java.util.Set.of(com.intertec.autoops.core.domain.CloudPlatform.KUBERNETES);

    @Test
    void aStepCannotUseAConnectionDedicatedToAnotherProject() {
        var alpha = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        var beta = projectService.create(TENANT, ACTOR, TOKEN, "Beta", null);
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "kubernetes", "Alpha Cluster",
                "{\"kubeconfig\":\"apiVersion: v1\"}", alpha.getId());

        // Alpha's own run resolves it...
        assertTrue(cloudConnectionService
                .resolveForStep(TENANT, alpha.getId(), null, K8S).isPresent());
        // ...Beta's run must not see it at all.
        assertTrue(cloudConnectionService
                .resolveForStep(TENANT, beta.getId(), null, K8S).isEmpty(),
                "a project-dedicated integration is invisible to other projects");
    }

    @Test
    void namingAnotherProjectsConnectionIsRefusedExplicitly() {
        var alpha = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        var beta = projectService.create(TENANT, ACTOR, TOKEN, "Beta", null);
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "kubernetes", "Alpha Cluster",
                "{\"kubeconfig\":\"apiVersion: v1\"}", alpha.getId());

        CoreException ex = assertThrows(CoreException.class,
                () -> cloudConnectionService.resolveForStep(TENANT, beta.getId(),
                        "Alpha Cluster", K8S));
        assertEquals("connection_not_in_project", ex.getError(),
                "naming it outright must not bypass the project boundary");
    }

    @Test
    void globalConnectionsStayAvailableToEveryProjectAndToAdHocRuns() {
        var alpha = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "kubernetes", "Shared Cluster",
                "{\"kubeconfig\":\"apiVersion: v1\"}");

        assertTrue(cloudConnectionService
                .resolveForStep(TENANT, alpha.getId(), null, K8S).isPresent());
        assertTrue(cloudConnectionService.resolveForStep(TENANT, null, null, K8S).isPresent(),
                "no project context still reaches global integrations");
    }

    @Test
    void adHocRunsCannotReachAProjectDedicatedConnection() {
        var alpha = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "kubernetes", "Alpha Cluster",
                "{\"kubeconfig\":\"apiVersion: v1\"}", alpha.getId());

        assertTrue(cloudConnectionService.resolveForStep(TENANT, null, null, K8S).isEmpty(),
                "a command with no project context must not borrow a project's account");
    }

    @Test
    void scopingNarrowsAnOtherwiseAmbiguousMatch() {
        var alpha = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "kubernetes", "Alpha Cluster",
                "{\"kubeconfig\":\"apiVersion: v1\"}", alpha.getId());
        cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "kubernetes", "Beta Cluster",
                "{\"kubeconfig\":\"apiVersion: v1\"}",
                projectService.create(TENANT, ACTOR, TOKEN, "Beta", null).getId());

        // Two clusters exist, but exactly one is visible to Alpha, so the
        // step no longer has to name it.
        assertEquals("Alpha Cluster", cloudConnectionService
                .resolveForStep(TENANT, alpha.getId(), null, K8S).orElseThrow().name());
    }

    @Test
    void preflightVerificationStoresNothing() {
        when(verificationClient.verify(eq(TENANT), eq("AZURE"), any())).thenReturn(
                new com.intertec.autoops.core.client.VerificationClient.VerifyResult(
                        true, true, "Service principal authenticated with Microsoft Entra ID",
                        "sub-guid", "Contoso Production", java.util.Map.of()));

        var outcome = cloudConnectionService.verifyCredentials(TENANT, ACTOR, TOKEN, "azure",
                "{\"clientId\":\"c\",\"clientSecret\":\"s\",\"tenantId\":\"t\"}");

        assertTrue(outcome.verified());
        assertEquals("Contoso Production", outcome.accountName(),
                "the account name must be visible BEFORE the connection is created");
        assertEquals(null, outcome.checkedAt(), "a preflight is not a recorded check");
        assertTrue(cloudConnectionRepository.findByTenantIdOrderByCreatedAtDesc(TENANT).isEmpty(),
                "abandoning the dialog must leave no connection behind");
    }

    @Test
    void preflightRejectsAnUnknownPlatformBeforeCallingTheProvider() {
        CoreException ex = assertThrows(CoreException.class,
                () -> cloudConnectionService.verifyCredentials(TENANT, ACTOR, TOKEN, "digitalocean",
                        "{\"token\":\"x\"}"));
        assertEquals("unknown_platform", ex.getError());
        verify(verificationClient, never()).verify(any(), any(), any());
    }

    @Test
    void verifiedIdentityFromTheProviderBeatsWhatTheUserTyped() {
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "azure",
                "Azure Prod", "{\"clientId\":\"c\",\"clientSecret\":\"s\",\"tenantId\":\"t\","
                        + "\"subscriptionId\":\"sub-typed\",\"region\":\"westeurope\"}");
        // Before verification only the typed subscription id is known.
        assertEquals("sub-typed", cloudConnectionService.describe(connection).accountId());
        assertEquals(null, cloudConnectionService.describe(connection).accountName());

        when(verificationClient.verify(eq(TENANT), eq("AZURE"), any())).thenReturn(
                new com.intertec.autoops.core.client.VerificationClient.VerifyResult(
                        true, true, "Service principal authenticated with Microsoft Entra ID",
                        "0000-sub-guid", "Contoso Production", java.util.Map.of()));
        cloudConnectionService.verify(TENANT, ACTOR, TOKEN, connection.getId());

        var stored = cloudConnectionRepository.findByIdAndTenantId(connection.getId(), TENANT)
                .orElseThrow();
        var info = cloudConnectionService.describe(stored);
        assertEquals("0000-sub-guid", info.accountId());
        assertEquals("Contoso Production", info.accountName());
        assertEquals("westeurope", info.region(), "region still comes from the credentials");
    }

    @Test
    void aFailedRecheckKeepsTheLastKnownIdentity() {
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws",
                "AWS Prod", "{\"accessId\":\"AKIAIOSFODNN7EXAMPLE\",\"secret\":\"s\"}");
        when(verificationClient.verify(eq(TENANT), eq("AWS"), any())).thenReturn(
                new com.intertec.autoops.core.client.VerificationClient.VerifyResult(
                        true, true, "Authenticated with AWS", "123456789012", "autoops-ci", java.util.Map.of()));
        cloudConnectionService.verify(TENANT, ACTOR, TOKEN, connection.getId());

        // Keys rotated away: the check now fails, but which account this
        // points at is still known.
        when(verificationClient.verify(eq(TENANT), eq("AWS"), any())).thenReturn(
                new com.intertec.autoops.core.client.VerificationClient.VerifyResult(
                        true, false, "AWS rejected the credentials", null, null, java.util.Map.of()));
        cloudConnectionService.verify(TENANT, ACTOR, TOKEN, connection.getId());

        var stored = cloudConnectionRepository.findByIdAndTenantId(connection.getId(), TENANT)
                .orElseThrow();
        assertEquals(Boolean.FALSE, stored.getLastVerifiedOk());
        var info = cloudConnectionService.describe(stored);
        assertEquals("123456789012", info.accountId());
        assertEquals("autoops-ci", info.accountName());
    }

    @Test
    void disconnectClearsTheVerifiedIdentityToo() {
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws",
                "AWS Prod", "{\"accessId\":\"AKIA\",\"secret\":\"s\"}");
        when(verificationClient.verify(eq(TENANT), eq("AWS"), any())).thenReturn(
                new com.intertec.autoops.core.client.VerificationClient.VerifyResult(
                        true, true, "ok", "123456789012", "autoops-ci", java.util.Map.of()));
        cloudConnectionService.verify(TENANT, ACTOR, TOKEN, connection.getId());
        cloudConnectionService.disconnect(TENANT, TOKEN, connection.getId());

        var stored = cloudConnectionRepository.findByIdAndTenantId(connection.getId(), TENANT)
                .orElseThrow();
        assertEquals(null, stored.getVerifiedAccountId());
        assertEquals(null, stored.getVerifiedAccountName());
    }

    @Test
    void describeOfAConnectionWithoutCredentialsIsEmptyNotAnError() {
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "gcp",
                "GCP Dev", null);
        var info = cloudConnectionService.describe(connection);
        assertEquals(null, info.accountId());
        assertEquals(null, info.region());
    }

    @Test
    void connectionCanBeScopedToAProjectAndBackToGlobal() {
        var project = projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null);
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws",
                "AWS Alpha", null, project.getId());
        assertEquals(project.getId(), connection.getProjectId());

        var global = cloudConnectionService.assignProject(TENANT, TOKEN,
                connection.getId(), null);
        assertEquals(null, global.getProjectId(), "null assignment = global again");

        var reassigned = cloudConnectionService.assignProject(TENANT, TOKEN,
                connection.getId(), project.getId());
        assertEquals(project.getId(),
                cloudConnectionRepository.findByIdAndTenantId(reassigned.getId(), TENANT)
                        .orElseThrow().getProjectId());
    }

    @Test
    void connectionCannotBeAssignedToAnotherTenantsProject() {
        var foreign = projectService.create(OTHER_TENANT, ACTOR, TOKEN, "Foreign", null);
        var connection = cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "aws",
                "AWS Prod", null);

        CoreException ex = assertThrows(CoreException.class,
                () -> cloudConnectionService.assignProject(TENANT, TOKEN,
                        connection.getId(), foreign.getId()));
        assertEquals("project_not_found", ex.getError());
        CoreException ex2 = assertThrows(CoreException.class,
                () -> cloudConnectionService.connect(TENANT, ACTOR, TOKEN, "gcp",
                        "GCP Dev", null, foreign.getId()));
        assertEquals("project_not_found", ex2.getError());
    }

    @Test
    void entitlementOutageFailsClosedAs503() {
        when(entitlementClient.checkQuota(any(), eq("MAX_PROJECTS"), anyLong()))
                .thenReturn(new EntitlementClient.Decision(false, EntitlementClient.UNAVAILABLE, null, null));

        CoreException ex = assertThrows(CoreException.class,
                () -> projectService.create(TENANT, ACTOR, TOKEN, "Alpha", null));
        assertEquals(EntitlementClient.UNAVAILABLE, ex.getError());
        assertEquals(HttpStatus.SERVICE_UNAVAILABLE, ex.getStatus());
    }
}
