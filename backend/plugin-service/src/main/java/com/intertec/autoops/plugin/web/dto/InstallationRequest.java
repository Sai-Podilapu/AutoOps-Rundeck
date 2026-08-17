package com.intertec.autoops.plugin.web.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.util.Map;

/**
 * Install or reconfigure a channel.
 *
 * <p>There is no {@code tenantId} field, and there must never be one: the
 * tenant comes from the caller's token. A body-supplied tenant would let any
 * authenticated user write into another workspace.
 *
 * <p>On update, {@code pluginKey} is ignored — changing which plugin an
 * installation is would reinterpret its stored config against a different
 * field set. Delete and re-install instead.
 */
public record InstallationRequest(
        @NotBlank(message = "is required")
        String pluginKey,

        @NotBlank(message = "is required")
        @Size(max = 128, message = "must be 128 characters or fewer")
        String displayName,

        /**
         * Field name → value, matching the plugin's descriptor. Secrets the
         * caller omits are preserved from the stored config on update, because
         * the API never hands them back to be resubmitted.
         */
        Map<String, String> config) {
}
