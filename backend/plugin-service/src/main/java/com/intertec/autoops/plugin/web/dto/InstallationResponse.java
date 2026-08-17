package com.intertec.autoops.plugin.web.dto;

import com.intertec.autoops.plugin.domain.PluginInstallation;

import java.time.Instant;
import java.util.Map;

/**
 * A channel as the console sees it.
 *
 * <p>{@code config} holds non-secret values verbatim and secrets as a fixed
 * mask, never the real value — not even to the tenant that owns it. A stolen
 * session token should not be enough to walk away with a workspace's Slack
 * webhook and SMTP password.
 */
public record InstallationResponse(
        Long id,
        String pluginKey,
        String pluginName,
        String displayName,
        boolean enabled,
        String status,
        /** True when the platform stopped attempting delivery after failures. */
        boolean parked,
        Map<String, String> config,
        Boolean lastTestOk,
        Instant lastTestAt,
        String lastTestDetail,
        int consecutiveFailures,
        long ruleCount,
        String createdBy,
        Instant createdAt) {

    public static InstallationResponse from(PluginInstallation installation, String pluginName,
                                            Map<String, String> maskedConfig, long ruleCount) {
        return new InstallationResponse(
                installation.getId(),
                installation.getPluginKey(),
                pluginName,
                installation.getDisplayName(),
                installation.isEnabled(),
                installation.getStatus().name(),
                installation.getStatus() == PluginInstallation.Status.PARKED,
                maskedConfig,
                installation.getLastTestOk(),
                installation.getLastTestAt(),
                installation.getLastTestDetail(),
                installation.getConsecutiveFailures(),
                ruleCount,
                installation.getCreatedBy(),
                installation.getCreatedAt());
    }
}
