package com.intertec.autoops.plugin.web.dto;

import com.intertec.autoops.plugin.domain.DeliveryAttempt;

import java.time.Instant;

/**
 * One line of the delivery log. This is what answers "we never got the
 * alert" — the platform's existing email path has no equivalent, which is why
 * a silently dropped SendGrid message leaves no trace at all.
 */
public record DeliveryAttemptResponse(
        Long id,
        Long installationId,
        String pluginKey,
        Long ruleId,
        /** True when this was a manual connection test rather than a rule firing. */
        boolean connectionTest,
        String targetType,
        Long targetId,
        String targetName,
        String event,
        Long runId,
        boolean ok,
        Integer statusCode,
        String detail,
        Instant attemptedAt) {

    public static DeliveryAttemptResponse from(DeliveryAttempt attempt) {
        return new DeliveryAttemptResponse(
                attempt.getId(),
                attempt.getInstallationId(),
                attempt.getPluginKey(),
                attempt.getRuleId(),
                attempt.getRuleId() == null,
                attempt.getTargetType() == null ? null : attempt.getTargetType().name(),
                attempt.getTargetId(),
                attempt.getTargetName(),
                attempt.getEvent().name(),
                attempt.getRunId(),
                attempt.isOk(),
                attempt.getStatusCode(),
                attempt.getDetail(),
                attempt.getAttemptedAt());
    }
}
