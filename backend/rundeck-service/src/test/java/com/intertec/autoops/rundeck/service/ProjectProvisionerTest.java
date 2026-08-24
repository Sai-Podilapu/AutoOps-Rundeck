package com.intertec.autoops.rundeck.service;

import com.intertec.autoops.rundeck.client.RundeckApiClient;
import com.intertec.autoops.rundeck.config.RundeckProperties;
import com.intertec.autoops.rundeck.domain.RundeckProject;
import com.intertec.autoops.rundeck.exception.RundeckException;
import com.intertec.autoops.rundeck.repo.RundeckProjectRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * This class IS the tenant boundary now that one Rundeck serves every customer,
 * so these tests are the isolation argument written down.
 */
class ProjectProvisionerTest {

    private RundeckProjectRepository repository;
    private RundeckApiClient apiClient;
    private ProjectProvisioner provisioner;

    @BeforeEach
    void setUp() {
        repository = mock(RundeckProjectRepository.class);
        apiClient = mock(RundeckApiClient.class);
        RundeckProperties properties = new RundeckProperties();
        properties.getPlatform().setApiToken("platform-token");
        PlatformRundeck platform = new PlatformRundeck(properties);
        provisioner = new ProjectProvisioner(repository, platform, apiClient, properties);

        when(repository.save(any(RundeckProject.class))).thenAnswer(inv -> {
            RundeckProject p = inv.getArgument(0);
            if (p.getId() == null) {
                p.setId(1L);
            }
            return p;
        });
    }

    @Test
    @DisplayName("the project name is derived from the tenant, and the tenant is in it")
    void nameCarriesTheTenant() {
        assertThat(provisioner.projectName("acme-corp-a1b2c3d4", 7L))
                .isEqualTo("autoops-acme-corp-a1b2c3d4-7");
    }

    @Test
    @DisplayName("two tenants never land on the same project name")
    void tenantsDoNotCollide() {
        String a = provisioner.projectName("acme", 1L);
        String b = provisioner.projectName("globex", 1L);

        assertThat(a).isNotEqualTo(b);
    }

    @Test
    @DisplayName("the same tenant's two projects are separate")
    void projectsDoNotCollide() {
        assertThat(provisioner.projectName("acme", 1L))
                .isNotEqualTo(provisioner.projectName("acme", 2L));
    }

    @Test
    @DisplayName("a hostile workspace name cannot smuggle path, glob or separator characters")
    void sanitizeStripsDangerousCharacters() {
        // Each of these would mean something to a URL path, a Rundeck ACL glob,
        // or a node filter if it survived.
        assertThat(ProjectProvisioner.sanitize("../../etc/passwd")).isEqualTo("etc-passwd");
        assertThat(ProjectProvisioner.sanitize("acme*")).isEqualTo("acme");
        assertThat(ProjectProvisioner.sanitize("a b/c:d")).isEqualTo("a-b-c-d");
        assertThat(ProjectProvisioner.sanitize("ACME-Corp")).isEqualTo("acme-corp");
    }

    @Test
    @DisplayName("a tenant id of pure punctuation still yields a usable segment")
    void sanitizeNeverReturnsEmpty() {
        assertThat(ProjectProvisioner.sanitize("///")).isEqualTo("t");
        assertThat(ProjectProvisioner.sanitize("")).isEqualTo("t");
    }

    @Test
    @DisplayName("the tenant segment is length-bounded")
    void sanitizeBoundsLength() {
        String huge = "a".repeat(500);

        assertThat(ProjectProvisioner.sanitize(huge)).hasSize(48);
    }

    @Test
    @DisplayName("first use creates the project in the engine and records it")
    void firstUseProvisions() {
        when(repository.findByTenantIdAndProjectId("acme", 7L)).thenReturn(Optional.empty());

        String project = provisioner.ensureProject("acme", 7L);

        assertThat(project).isEqualTo("autoops-acme-7");
        verify(apiClient).ensureProject(any(), anyString());
    }

    @Test
    @DisplayName("a project already provisioned costs no API call")
    void provisionedIsCached() {
        RundeckProject existing = mapping(true);
        when(repository.findByTenantIdAndProjectId("acme", 7L)).thenReturn(Optional.of(existing));

        String project = provisioner.ensureProject("acme", 7L);

        assertThat(project).isEqualTo("autoops-acme-7");
        // The steady state is one indexed read per step, not a round trip.
        verify(apiClient, never()).ensureProject(any(), anyString());
    }

    @Test
    @DisplayName("a failed provision records the reason and refuses to run")
    void failedProvisionIsRecorded() {
        RundeckProject existing = mapping(false);
        when(repository.findByTenantIdAndProjectId("acme", 7L)).thenReturn(Optional.of(existing));
        doThrow(RundeckException.upstream("rundeck_unreachable", "connection refused"))
                .when(apiClient).ensureProject(any(), anyString());

        assertThatThrownBy(() -> provisioner.ensureProject("acme", 7L))
                .isInstanceOf(RundeckException.class);

        assertThat(existing.getLastError()).contains("connection refused");
        assertThat(existing.isProvisioned()).isFalse();
    }

    @Test
    @DisplayName("no tenant means no execution")
    void tenantIsRequired() {
        assertThatThrownBy(() -> provisioner.ensureProject("  ", 7L))
                .isInstanceOf(RundeckException.class)
                .hasMessageContaining("tenantId");
    }

    @Test
    @DisplayName("no project means no execution — there is no shared bucket to fall back to")
    void projectIsRequired() {
        // Falling back to a common project would put two tenants' output in one
        // place, which is the whole thing this class prevents.
        assertThatThrownBy(() -> provisioner.ensureProject("acme", null))
                .isInstanceOf(RundeckException.class)
                .hasMessageContaining("project is required");
    }

    private RundeckProject mapping(boolean provisioned) {
        RundeckProject mapping = new RundeckProject();
        mapping.setId(1L);
        mapping.setTenantId("acme");
        mapping.setProjectId(7L);
        mapping.setRundeckProject("autoops-acme-7");
        mapping.setProvisioned(provisioned);
        return mapping;
    }
}
