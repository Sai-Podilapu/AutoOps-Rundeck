package com.intertec.autoops.plugin.service;

import com.intertec.autoops.plugin.domain.PluginInstallation;
import com.intertec.autoops.plugin.exception.PluginException;
import com.intertec.autoops.plugin.repo.PluginInstallationRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Tenant isolation and secret handling — the two things that would be
 * genuinely damaging to get wrong here.
 */
@SpringBootTest
@Transactional
class InstallationServiceTest {

    private static final String TENANT_A = "tenant-a";
    private static final String TENANT_B = "tenant-b";

    @Autowired
    private InstallationService service;

    @Autowired
    private PluginInstallationRepository installations;

    private static Map<String, String> slackConfig(String url) {
        Map<String, String> config = new LinkedHashMap<>();
        config.put("webhookUrl", url);
        return config;
    }

    private PluginInstallation installSlack(String tenantId, String name) {
        return service.install(tenantId, "someone@example.com", "slack", name,
                slackConfig("https://hooks.slack.com/services/T1/B1/xxx"));
    }

    @Test
    void oneTenantCannotReadAnothersInstallation() {
        PluginInstallation mine = installSlack(TENANT_A, "Ops alerts");

        assertThatThrownBy(() -> service.get(TENANT_B, mine.getId()))
                .isInstanceOf(PluginException.class)
                .hasMessageContaining("No such integration");
    }

    @Test
    void oneTenantCannotDeleteAnothersInstallation() {
        PluginInstallation mine = installSlack(TENANT_A, "Ops alerts");

        assertThatThrownBy(() -> service.delete(TENANT_B, mine.getId()))
                .isInstanceOf(PluginException.class);
        assertThat(installations.findByIdAndTenantId(mine.getId(), TENANT_A)).isPresent();
    }

    @Test
    void listOnlyReturnsTheCallersOwnInstallations() {
        installSlack(TENANT_A, "Ops alerts");
        installSlack(TENANT_B, "Their alerts");

        assertThat(service.list(TENANT_A))
                .extracting(PluginInstallation::getDisplayName)
                .containsExactly("Ops alerts");
    }

    /** Two workspaces may both call a channel "Ops alerts". */
    @Test
    void nameUniquenessIsScopedToTheTenant() {
        installSlack(TENANT_A, "Ops alerts");

        assertThat(installSlack(TENANT_B, "Ops alerts").getId()).isNotNull();
    }

    @Test
    void aDuplicateNameWithinOneTenantIsRejected() {
        installSlack(TENANT_A, "Ops alerts");

        assertThatThrownBy(() -> installSlack(TENANT_A, "Ops alerts"))
                .isInstanceOf(PluginException.class)
                .hasMessageContaining("already exists");
    }

    @Test
    void secretsAreNeverReturnedInTheMaskedConfig() {
        PluginInstallation installation = installSlack(TENANT_A, "Ops alerts");

        Map<String, String> masked = service.maskedConfig(installation);

        assertThat(masked.get("webhookUrl")).isEqualTo("••••••••");
        assertThat(masked.toString()).doesNotContain("hooks.slack.com");
    }

    /**
     * The console cannot resend a secret it was never given, so an edit that
     * omits it must keep the stored value rather than wiping the channel.
     */
    @Test
    void updatingWithoutResendingTheSecretKeepsIt() {
        PluginInstallation installation = installSlack(TENANT_A, "Ops alerts");

        service.update(TENANT_A, installation.getId(), "Renamed", Map.of("username", "AutoOps"));

        PluginInstallation reloaded = service.get(TENANT_A, installation.getId());
        assertThat(reloaded.getDisplayName()).isEqualTo("Renamed");
        assertThat(service.context(reloaded).config())
                .containsEntry("webhookUrl", "https://hooks.slack.com/services/T1/B1/xxx")
                .containsEntry("username", "AutoOps");
    }

    /** Saying "last test: OK" about a credential since replaced would be a lie. */
    @Test
    void changingSettingsClearsTheStaleTestResult() {
        PluginInstallation installation = installSlack(TENANT_A, "Ops alerts");
        installation.setLastTestOk(true);
        installations.save(installation);

        service.update(TENANT_A, installation.getId(), null,
                slackConfig("https://hooks.slack.com/services/T2/B2/yyy"));

        assertThat(service.get(TENANT_A, installation.getId()).getLastTestOk()).isNull();
    }

    @Test
    void anUnknownConfigFieldIsRejectedRatherThanSilentlyStored() {
        Map<String, String> config = slackConfig("https://hooks.slack.com/services/T1/B1/x");
        config.put("channlName", "typo");

        assertThatThrownBy(() -> service.install(TENANT_A, "me", "slack", "Ops", config))
                .isInstanceOf(PluginException.class)
                .hasMessageContaining("not a setting");
    }

    @Test
    void aMissingRequiredFieldIsRejected() {
        assertThatThrownBy(() ->
                service.install(TENANT_A, "me", "slack", "Ops", Map.of("username", "AutoOps")))
                .isInstanceOf(PluginException.class)
                .hasMessageContaining("required");
    }

    /** http:// would put the webhook URL on the wire in clear text. */
    @Test
    void aPlainHttpUrlIsRejectedForAnHttpsField() {
        assertThatThrownBy(() -> service.install(TENANT_A, "me", "webhook", "Relay",
                Map.of("url", "http://events.example.com/autoops")))
                .isInstanceOf(PluginException.class)
                .hasMessageContaining("https://");
    }

    @Test
    void installingAnUnknownPluginIsRejected() {
        assertThatThrownBy(() ->
                service.install(TENANT_A, "me", "pagerduty", "Paging", Map.of()))
                .isInstanceOf(PluginException.class)
                .hasMessageContaining("No notification plugin named");
    }

    /** A parked channel comes back the moment the tenant re-enables it. */
    @Test
    void reEnablingClearsTheParkedState() {
        PluginInstallation installation = installSlack(TENANT_A, "Ops alerts");
        installation.recordFailure(1);
        installations.save(installation);
        assertThat(installation.getStatus()).isEqualTo(PluginInstallation.Status.PARKED);

        PluginInstallation reEnabled = service.setEnabled(TENANT_A, installation.getId(), true);

        assertThat(reEnabled.getStatus()).isEqualTo(PluginInstallation.Status.ACTIVE);
        assertThat(reEnabled.getConsecutiveFailures()).isZero();
    }
}
