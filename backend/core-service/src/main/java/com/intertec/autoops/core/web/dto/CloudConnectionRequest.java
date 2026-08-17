package com.intertec.autoops.core.web.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * platform is one of AWS|AZURE|GCP|HUAWEI|ORACLE|M365|KUBERNETES
 * (case-insensitive). credentials (optional) is a JSON object of the
 * platform's fields — stored encrypted, never returned. projectId (optional)
 * scopes the connection to one of the tenant's projects; null = global.
 */
public record CloudConnectionRequest(
        @NotBlank String platform,
        @NotBlank @Size(max = 128) String name,
        String credentials,
        Long projectId) {
}
