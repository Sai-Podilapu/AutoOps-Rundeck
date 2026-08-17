package com.intertec.autoops.plugin.repo;

import com.intertec.autoops.plugin.domain.DeliveryAttempt;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.List;

public interface DeliveryAttemptRepository extends JpaRepository<DeliveryAttempt, Long> {

    List<DeliveryAttempt> findByTenantIdOrderByAttemptedAtDesc(String tenantId, Pageable pageable);

    List<DeliveryAttempt> findByTenantIdAndInstallationIdOrderByAttemptedAtDesc(
            String tenantId, Long installationId, Pageable pageable);

    /**
     * Retention trim. This table grows with every run times every matching
     * channel, so it is the fastest-growing table in the service and needs a
     * bound; without one it becomes the reason the database fills up.
     */
    @Modifying
    @Query("DELETE FROM DeliveryAttempt d WHERE d.attemptedAt < :cutoff")
    int deleteOlderThan(@Param("cutoff") Instant cutoff);
}
