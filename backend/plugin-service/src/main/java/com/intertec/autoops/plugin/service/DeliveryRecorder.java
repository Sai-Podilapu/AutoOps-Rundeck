package com.intertec.autoops.plugin.service;

import com.intertec.autoops.plugin.config.PluginProperties;
import com.intertec.autoops.plugin.domain.DeliveryAttempt;
import com.intertec.autoops.plugin.domain.PluginInstallation;
import com.intertec.autoops.plugin.repo.DeliveryAttemptRepository;
import com.intertec.autoops.plugin.repo.PluginInstallationRepository;
import com.intertec.autoops.plugin.spi.DeliveryResult;
import com.intertec.autoops.plugin.spi.NotificationMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Writes the outcome of a delivery attempt and maintains the failure counter.
 *
 * <p>A separate bean from {@code DispatchService} on purpose: these run on a
 * worker thread after the originating request has returned, and a
 * {@code @Transactional} method called from inside the same class would bypass
 * the proxy and silently run without a transaction.
 */
@Service
public class DeliveryRecorder {

    private static final Logger log = LoggerFactory.getLogger(DeliveryRecorder.class);

    private final PluginInstallationRepository installations;
    private final DeliveryAttemptRepository attempts;
    private final PluginProperties properties;

    public DeliveryRecorder(PluginInstallationRepository installations,
                            DeliveryAttemptRepository attempts,
                            PluginProperties properties) {
        this.installations = installations;
        this.attempts = attempts;
        this.properties = properties;
    }

    /**
     * REQUIRES_NEW so one channel's bookkeeping cannot roll back another's.
     * Each delivery is an independent fact.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void record(String tenantId, Long installationId, String pluginKey, Long ruleId,
                       NotificationMessage message, DeliveryResult result) {
        DeliveryAttempt attempt = new DeliveryAttempt();
        attempt.setTenantId(tenantId);
        attempt.setInstallationId(installationId);
        attempt.setPluginKey(pluginKey);
        attempt.setRuleId(ruleId);
        attempt.setTargetType(message.targetType());
        attempt.setTargetId(message.targetId());
        attempt.setTargetName(message.targetName());
        attempt.setEvent(message.event());
        attempt.setRunId(message.runId());
        attempt.setOk(result.ok());
        attempt.setStatusCode(result.statusCode());
        attempt.setDetail(result.detailForStorage());
        attempts.save(attempt);

        installations.findByIdAndTenantId(installationId, tenantId).ifPresent(installation -> {
            if (result.ok()) {
                installation.recordSuccess();
            } else if (!result.retryable()) {
                // Only permanent failures count toward parking. A timeout must
                // never park a channel that is merely slow — that would turn a
                // network blip into silence that nobody notices.
                installation.recordFailure(properties.getDelivery().getMaxConsecutiveFailures());
                if (installation.getStatus() == PluginInstallation.Status.PARKED) {
                    log.warn("Parked integration {} ({}) for tenant {} after {} consecutive "
                                    + "permanent failures; last error: {}",
                            installation.getDisplayName(), pluginKey, tenantId,
                            installation.getConsecutiveFailures(), result.detailForStorage());
                }
            }
            installations.save(installation);
        });
    }
}
