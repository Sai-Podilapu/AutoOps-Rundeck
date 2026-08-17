package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.domain.RefreshTokenSession;
import com.intertec.autoops.auth.domain.User;
import com.intertec.autoops.auth.domain.UserRole;
import com.intertec.autoops.auth.domain.UserStatus;
import com.intertec.autoops.auth.exception.AuthException;
import com.intertec.autoops.auth.repo.RefreshTokenSessionRepository;
import com.intertec.autoops.auth.repo.UserRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.context.annotation.Import;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Rotation + reuse detection against a real (H2) database with REAL
 * transaction semantics: the class-level NOT_SUPPORTED disables the
 * test-managed transaction so each service call commits or rolls back for
 * real — which is exactly what the reuse-detection regression needs to catch
 * (the family revocation used to be rolled back by the thrown AuthException).
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Import({RefreshTokenService.class, AuditService.class})
@EnableConfigurationProperties(AuthProperties.class)
@Transactional(propagation = Propagation.NOT_SUPPORTED)
class RefreshTokenServiceTest {

    @Autowired
    private RefreshTokenService refreshTokenService;
    @Autowired
    private RefreshTokenSessionRepository sessionRepository;
    @Autowired
    private UserRepository userRepository;

    private User user;

    @BeforeEach
    void setUp() {
        sessionRepository.deleteAll();
        userRepository.deleteAll();
        User u = new User();
        u.setEmail("alice@example.com");
        u.setRole(UserRole.ADMIN);
        u.setStatus(UserStatus.ACTIVE);
        u.setTenantId("tenant-a");
        u.setTokenVersion(0);
        user = userRepository.save(u);
    }

    @Test
    void rotateIssuesNewSessionAndRevokesOld() {
        RefreshTokenService.IssuedRefreshToken issued =
                refreshTokenService.createSession(user, "device-1", "1.2.3.4", "junit");

        RefreshTokenService.RotationResult result =
                refreshTokenService.rotate(issued.token(), "1.2.3.4", "junit");

        RefreshTokenSession old = sessionRepository.findById(issued.session().getSessionId()).orElseThrow();
        assertNotNull(old.getRevokedAt());
        assertEquals(result.newSession().getSessionId(), old.getReplacedBySession());
        RefreshTokenSession replacement = sessionRepository.findById(result.newSession().getSessionId()).orElseThrow();
        assertNull(replacement.getRevokedAt());
    }

    @Test
    void replayingRotatedTokenRevokesWholeFamily_persistently() {
        RefreshTokenService.IssuedRefreshToken issued =
                refreshTokenService.createSession(user, "device-1", "1.2.3.4", "junit");
        RefreshTokenService.RotationResult rotated =
                refreshTokenService.rotate(issued.token(), "1.2.3.4", "junit");

        // Replay of the OLD (already-rotated) token = reuse.
        AuthException ex = assertThrows(AuthException.class,
                () -> refreshTokenService.rotate(issued.token(), "6.6.6.6", "attacker"));
        assertEquals("refresh_reuse_detected", ex.getError());

        // The revocation must have COMMITTED despite the exception: both the
        // replayed session and its live replacement are dead in the database.
        RefreshTokenSession old = sessionRepository.findById(issued.session().getSessionId()).orElseThrow();
        RefreshTokenSession replacement =
                sessionRepository.findById(rotated.newSession().getSessionId()).orElseThrow();
        assertTrue(old.isReuseDetected());
        assertTrue(replacement.isReuseDetected());
        assertNotNull(replacement.getRevokedAt(), "family revocation must persist");

        // And the replacement token must now be unusable.
        AuthException replayEx = assertThrows(AuthException.class,
                () -> refreshTokenService.rotate(rotated.newRefreshToken(), "1.2.3.4", "junit"));
        assertEquals("refresh_reuse_detected", replayEx.getError());
    }

    @Test
    void bogusTokenIsRejected() {
        AuthException ex = assertThrows(AuthException.class,
                () -> refreshTokenService.rotate("not-a-token", "1.2.3.4", "junit"));
        assertEquals("invalid_refresh_token", ex.getError());
    }
}
