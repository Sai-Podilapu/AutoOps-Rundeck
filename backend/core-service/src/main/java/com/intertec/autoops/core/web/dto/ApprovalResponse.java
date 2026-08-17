package com.intertec.autoops.core.web.dto;

import com.intertec.autoops.core.domain.Approval;

import java.time.Instant;

public record ApprovalResponse(
        Long id,
        Long projectId,
        String targetType,
        Long targetId,
        String targetName,
        String requestedBy,
        String status,
        String decidedBy,
        Instant decidedAt,
        Long runId,
        Instant createdAt) {

    public static ApprovalResponse from(Approval a) {
        return new ApprovalResponse(a.getId(), a.getProjectId(), a.getTargetType().name(),
                a.getTargetId(), a.getTargetName(), a.getRequestedBy(), a.getStatus().name(),
                a.getDecidedBy(), a.getDecidedAt(), a.getRunId(), a.getCreatedAt());
    }
}