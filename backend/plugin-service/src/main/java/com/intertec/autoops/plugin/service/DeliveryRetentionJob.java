package com.intertec.autoops.plugin.service;

import com.intertec.autoops.plugin.config.PluginProperties;
import com.intertec.autoops.plugin.repo.DeliveryAttemptRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;

/**
 * Trims the delivery log.
 *
 * <p>{@code delivery_attempts} gains a row for every run times every matching
 * channel, which makes it the fastest-growing table in the service. Left
 * alone it is what eventually fills the disk, so the bound is not optional.
 *
 * <p>Unlike core-service's scheduler this takes no database lease, so with
 * several replicas each will run its own sweep. That is harmless here — the
 * delete is idempotent and bounded by the same cutoff — but it would not be
 * for anything that produced side effects.
 */
@Component
public class DeliveryRetentionJob {

    private static final Logger log = LoggerFactory.getLogger(DeliveryRetentionJob.class);

    private final DeliveryAttemptRepository attempts;
    private final Duration retention;

    public DeliveryRetentionJob(DeliveryAttemptRepository attempts,
                                PluginProperties properties) {
        this.attempts = attempts;
        this.retention = properties.getDelivery().getRetention();
    }

    @Scheduled(
            initialDelayString = "${autoops.plugin.delivery.retention-initial-delay:PT5M}",
            fixedDelayString = "${autoops.plugin.delivery.retention-interval:PT12H}")
    @Transactional
    public void trim() {
        Instant cutoff = Instant.now().minus(retention);
        int deleted = attempts.deleteOlderThan(cutoff);
        if (deleted > 0) {
            log.info("Trimmed {} delivery attempt(s) older than {}", deleted, cutoff);
        }
    }
}
