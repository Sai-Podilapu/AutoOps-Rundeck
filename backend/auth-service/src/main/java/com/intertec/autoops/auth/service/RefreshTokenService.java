package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.domain.AuditEventType;
import com.intertec.autoops.auth.domain.RefreshTokenSession;
import com.intertec.autoops.auth.domain.User;
import com.intertec.autoops.auth.domain.UserStatus;
import com.intertec.autoops.auth.exception.AuthException;
import com.intertec.autoops.auth.repo.RefreshTokenSessionRepository;
import com.intertec.autoops.auth.repo.UserRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.Base64;
import java.util.List;
import java.util.UUID;

/**
 * Opaque refresh tokens: {@code {sessionId}.{48-byte-secret}} (Base64URL, no
 * padding). Only the SHA-256 hash is stored. Rotation revokes the old session
 * and links replaced_by_session; presenting an already-rotated/revoked token
 * flags reuse and revokes the whole session family (chain walk, guard 1000).
 */
@Service
public class RefreshTokenService {

    private static final Logger log = LoggerFactory.getLogger(RefreshTokenService.class);
    private static final int SECRET_BYTES = 48;
    private static final int FAMILY_WALK_GUARD = 1000;
    private static final SecureRandom RANDOM = new SecureRandom();

    private final RefreshTokenSessionRepository sessionRepository;
    private final UserRepository userRepository;
    private final AuthProperties properties;
    private final AuditService auditService;

    public RefreshTokenService(RefreshTokenSessionRepository sessionRepository,
                               UserRepository userRepository,
                               AuthProperties properties,
                               AuditService auditService) {
        this.sessionRepository = sessionRepository;
        this.userRepository = userRepository;
        this.properties = properties;
        this.auditService = auditService;
    }

    /** Plaintext token + persisted session (only the hash is stored). */
    public record IssuedRefreshToken(String token, RefreshTokenSession session) {
    }

    public record RotationResult(User user, String newRefreshToken, RefreshTokenSession newSession) {
    }

    @Transactional
    public IssuedRefreshToken createSession(User user, String deviceId, String ipAddress,
                                            String userAgent) {
        String sessionId = UUID.randomUUID().toString();
        byte[] secret = new byte[SECRET_BYTES];
        RANDOM.nextBytes(secret);
        String token = sessionId + "." + Base64.getUrlEncoder().withoutPadding().encodeToString(secret);

        RefreshTokenSession session = new RefreshTokenSession();
        session.setSessionId(sessionId);
        session.setUserId(user.getId());
        session.setTenantId(user.getTenantId());
        session.setTokenHash(OtpService.sha256Hex(token));
        session.setDeviceId(deviceId);
        session.setIpAddress(ipAddress);
        session.setUserAgent(userAgent);
        session.setIssuedAt(Instant.now());
        session.setExpiresAt(Instant.now().plus(properties.getRefreshTokenTtl()));
        sessionRepository.save(session);

        return new IssuedRefreshToken(token, session);
    }

    // noRollbackFor: the reuse-detection path below persists the family
    // revocation and audit row and THEN throws. Without it the AuthException
    // would mark the transaction rollback-only and silently undo the
    // revocation — the advertised guarantee would never reach the database.
    // Every other throw in this method happens before any write.
    @Transactional(noRollbackFor = AuthException.class)
    public RotationResult rotate(String refreshToken, String ipAddress, String userAgent) {
        RefreshTokenSession session = requireMatchingSession(refreshToken);

        // Reuse detection: a rotated or revoked token is being replayed.
        if (session.getRevokedAt() != null || session.getReplacedBySession() != null) {
            int revoked = revokeFamily(session);
            auditService.record(AuditEventType.REFRESH_REUSE, session.getUserId(), null,
                    session.getTenantId(), session.getSessionId(), ipAddress, userAgent,
                    "familyRevoked=" + revoked);
            throw AuthException.unauthorized("refresh_reuse_detected",
                    "Refresh token reuse detected. All sessions have been revoked.");
        }
        if (Instant.now().isAfter(session.getExpiresAt())) {
            throw AuthException.unauthorized("refresh_expired", "Refresh token has expired");
        }

        User user = userRepository.findById(session.getUserId())
                .orElseThrow(() -> AuthException.unauthorized("invalid_refresh_token",
                        "Refresh token is invalid"));
        if (user.getStatus() != UserStatus.ACTIVE) {
            throw AuthException.forbidden("user_not_active", "Account is not active");
        }

        IssuedRefreshToken replacement = createSession(user, session.getDeviceId(), ipAddress,
                userAgent);
        session.setRevokedAt(Instant.now());
        session.setReplacedBySession(replacement.session().getSessionId());
        sessionRepository.save(session);

        auditService.record(AuditEventType.TOKEN_REFRESH, user.getId(), user.getEmail(),
                user.getTenantId(), replacement.session().getSessionId(), ipAddress, userAgent, null);

        return new RotationResult(user, replacement.token(), replacement.session());
    }

    /** Idempotent single-session logout. */
    @Transactional
    public void revokeByToken(String refreshToken, String ipAddress, String userAgent) {
        RefreshTokenSession session;
        try {
            session = requireMatchingSession(refreshToken);
        } catch (AuthException ex) {
            log.debug("Logout with unknown refresh token ignored");
            return;
        }
        if (session.getRevokedAt() == null) {
            session.setRevokedAt(Instant.now());
            sessionRepository.save(session);
            auditService.record(AuditEventType.LOGOUT, session.getUserId(), null,
                    session.getTenantId(), session.getSessionId(), ipAddress, userAgent, null);
        }
    }

    @Transactional
    public int revokeAllForUser(Long userId) {
        List<RefreshTokenSession> sessions = sessionRepository.findByUserIdAndRevokedAtIsNull(userId);
        Instant now = Instant.now();
        for (RefreshTokenSession session : sessions) {
            session.setRevokedAt(now);
        }
        sessionRepository.saveAll(sessions);
        return sessions.size();
    }

    // ------------------------------------------------------------------

    /** Parses {sessionId}.{secret}, loads the session, and constant-time checks the hash. */
    private RefreshTokenSession requireMatchingSession(String refreshToken) {
        if (refreshToken == null) {
            throw AuthException.unauthorized("invalid_refresh_token", "Refresh token is invalid");
        }
        int separator = refreshToken.indexOf('.');
        if (separator <= 0) {
            throw AuthException.unauthorized("invalid_refresh_token", "Refresh token is invalid");
        }
        String sessionId = refreshToken.substring(0, separator);
        // SELECT ... FOR UPDATE: concurrent presentations of the same token
        // serialize on the session row, so rotation + reuse detection cannot
        // be raced by parallel requests.
        RefreshTokenSession session = sessionRepository.findWithLockBySessionId(sessionId)
                .orElseThrow(() -> AuthException.unauthorized("invalid_refresh_token",
                        "Refresh token is invalid"));
        boolean matches = MessageDigest.isEqual(
                session.getTokenHash().getBytes(StandardCharsets.UTF_8),
                OtpService.sha256Hex(refreshToken).getBytes(StandardCharsets.UTF_8));
        if (!matches) {
            throw AuthException.unauthorized("invalid_refresh_token", "Refresh token is invalid");
        }
        return session;
    }

    /** Marks the session and every successor in its rotation chain as reused/revoked. */
    private int revokeFamily(RefreshTokenSession start) {
        int count = 0;
        Instant now = Instant.now();
        RefreshTokenSession current = start;
        for (int i = 0; i < FAMILY_WALK_GUARD && current != null; i++) {
            current.setReuseDetected(true);
            if (current.getRevokedAt() == null) {
                current.setRevokedAt(now);
            }
            sessionRepository.save(current);
            count++;
            String nextId = current.getReplacedBySession();
            current = nextId != null ? sessionRepository.findById(nextId).orElse(null) : null;
        }
        return count;
    }
}
