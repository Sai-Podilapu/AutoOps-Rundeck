package com.intertec.autoops.plugin.web.dto;

import com.intertec.autoops.plugin.domain.LifecycleEvent;
import com.intertec.autoops.plugin.domain.TargetType;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;

import java.util.Set;

/**
 * "Send me {events} for {scope} through {installationId}."
 *
 * <p>Scope widens as the ids go null — {@code targetId} for one job or
 * workflow, {@code projectId} for a whole project, neither for the entire
 * workspace. Sending both is not an error; {@code targetId} wins and
 * {@code projectId} is discarded, since a specific target already implies its
 * project.
 */
public record RuleRequest(
        @NotNull(message = "is required")
        Long installationId,

        @NotNull(message = "is required")
        TargetType targetType,

        /** Null for every target of this type in scope. */
        Long targetId,

        /** Null for every project. Ignored when targetId is set. */
        Long projectId,

        @NotEmpty(message = "select at least one event")
        Set<LifecycleEvent> events,

        Boolean enabled) {
}
