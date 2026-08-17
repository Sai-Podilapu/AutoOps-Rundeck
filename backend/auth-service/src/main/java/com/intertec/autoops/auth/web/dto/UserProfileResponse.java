package com.intertec.autoops.auth.web.dto;

import com.intertec.autoops.auth.domain.User;

public record UserProfileResponse(
        Long id,
        String email,
        String fullName,
        String role,
        String status,
        String tenantId,
        /** Human-readable workspace name; null for pre-V5 tenants (clients prettify the slug). */
        String workspaceName) {

    public static UserProfileResponse from(User user, String workspaceName) {
        return new UserProfileResponse(
                user.getId(),
                user.getEmail(),
                user.getFullName(),
                user.getRole() != null ? user.getRole().name() : null,
                user.getStatus() != null ? user.getStatus().name() : null,
                user.getTenantId(),
                workspaceName);
    }
}
