package com.intertec.autoops.auth.repo;

import com.intertec.autoops.auth.domain.AuthAuditLog;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;

public interface AuthAuditLogRepository extends JpaRepository<AuthAuditLog, Long> {

    /** Retention sweep: audit rows older than the configured window. */
    @Modifying
    @Query("delete from AuthAuditLog a where a.createdAt < :cutoff")
    int deleteByCreatedAtBefore(@Param("cutoff") Instant cutoff);
}
