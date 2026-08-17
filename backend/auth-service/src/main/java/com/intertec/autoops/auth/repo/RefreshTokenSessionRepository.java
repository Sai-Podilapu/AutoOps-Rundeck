package com.intertec.autoops.auth.repo;

import com.intertec.autoops.auth.domain.RefreshTokenSession;
import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.List;
import java.util.Optional;

public interface RefreshTokenSessionRepository extends JpaRepository<RefreshTokenSession, String> {

    List<RefreshTokenSession> findByUserIdAndRevokedAtIsNull(Long userId);

    List<RefreshTokenSession> findByUserIdAndDeviceIdAndRevokedAtIsNull(Long userId, String deviceId);

    /**
     * SELECT ... FOR UPDATE — serializes concurrent rotations of the same
     * refresh token so reuse detection cannot be raced.
     */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select s from RefreshTokenSession s where s.sessionId = :sessionId")
    Optional<RefreshTokenSession> findWithLockBySessionId(@Param("sessionId") String sessionId);

    /**
     * Retention sweep: sessions expired or revoked before the cutoff. Kept for
     * a grace window (forensics on reuse incidents) rather than deleted eagerly.
     */
    @Modifying
    @Query("delete from RefreshTokenSession s where s.expiresAt < :cutoff"
            + " or (s.revokedAt is not null and s.revokedAt < :cutoff)")
    int deleteExpiredOrRevokedBefore(@Param("cutoff") Instant cutoff);
}
