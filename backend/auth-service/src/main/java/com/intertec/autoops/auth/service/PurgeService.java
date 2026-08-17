package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.repo.AuthAuditLogRepository;
import com.intertec.autoops.auth.repo.OtpRepository;
import com.intertec.autoops.auth.repo.RefreshTokenSessionRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;

/**
 * Hourly retention sweep so auth tables don't grow forever:
 * <ul>
 *   <li>otp_entries — expired challenges past {@code retention.otp-entries}</li>
 *   <li>refresh_token_sessions — expired/revoked past {@code retention.refresh-sessions}
 *       (grace window keeps reuse-incident forensics available)</li>
 *   <li>auth_audit_log — rows past {@code retention.audit-log}</li>
 * </ul>
 * Deletes are idempotent, so concurrent instances need no leader election.
 */
@Service
public class PurgeService {

    private static final Logger log = LoggerFactory.getLogger(PurgeService.class);

    private final OtpRepository otpRepository;
    private final RefreshTokenSessionRepository sessionRepository;
    private final AuthAuditLogRepository auditLogRepository;
    private final AuthProperties properties;

    public PurgeService(OtpRepository otpRepository,
                        RefreshTokenSessionRepository sessionRepository,
                        AuthAuditLogRepository auditLogRepository,
                        AuthProperties properties) {
        this.otpRepository = otpRepository;
        this.sessionRepository = sessionRepository;
        this.auditLogRepository = auditLogRepository;
        this.properties = properties;
    }

    @Scheduled(initialDelayString = "PT1M", fixedDelayString = "PT1H")
    @Transactional
    public void purge() {
        Instant now = Instant.now();
        AuthProperties.Retention retention = properties.getRetention();
        int otps = otpRepository.deleteByExpiresAtBefore(now.minus(retention.getOtpEntries()));
        int sessions = sessionRepository.deleteExpiredOrRevokedBefore(
                now.minus(retention.getRefreshSessions()));
        int audits = auditLogRepository.deleteByCreatedAtBefore(now.minus(retention.getAuditLog()));
        if (otps > 0 || sessions > 0 || audits > 0) {
            log.info("Retention purge: {} otp entries, {} sessions, {} audit rows",
                    otps, sessions, audits);
        }
    }
}
