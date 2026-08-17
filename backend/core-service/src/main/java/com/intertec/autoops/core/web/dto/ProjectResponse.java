package com.intertec.autoops.core.web.dto;

import com.intertec.autoops.core.domain.Project;

import java.time.Instant;

public record ProjectResponse(
        Long id,
        String name,
        String description,
        String status,
        String createdBy,
        Instant createdAt,
        Instant updatedAt) {

    public static ProjectResponse from(Project project) {
        return new ProjectResponse(project.getId(), project.getName(), project.getDescription(),
                project.getStatus().name(), project.getCreatedBy(),
                project.getCreatedAt(), project.getUpdatedAt());
    }
}
