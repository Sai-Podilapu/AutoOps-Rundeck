package com.intertec.autoops.core.web.dto;

import com.intertec.autoops.core.domain.CloudConnection;
import com.intertec.autoops.core.service.CloudAccountDescriptor;

import java.time.Instant;

/**
 * Credentials are NEVER returned — only whether they exist, plus the
 * non-secret account/region identity derived from them.
 */
public record CloudConnectionResponse(
        Long id,
        String platform,
        String name,
        Long projectId,
        String accountId,
        String accountName,
        String region,
        String status,
        boolean hasCredentials,
        Instant lastVerifiedAt,
        Boolean lastVerifiedOk,
        String lastVerifiedMessage,
        String createdBy,
        Instant createdAt) {

    public static CloudConnectionResponse from(CloudConnection connection) {
        return from(connection, CloudAccountDescriptor.AccountInfo.EMPTY);
    }

    public static CloudConnectionResponse from(CloudConnection connection,
                                               CloudAccountDescriptor.AccountInfo account) {
        return new CloudConnectionResponse(connection.getId(), connection.getPlatform().name(),
                connection.getName(), connection.getProjectId(),
                account.accountId(), account.accountName(), account.region(),
                connection.getStatus().name(),
                connection.getCredentialsEnc() != null,
                connection.getLastVerifiedAt(), connection.getLastVerifiedOk(),
                connection.getLastVerifiedMessage(), connection.getCreatedBy(),
                connection.getCreatedAt());
    }
}