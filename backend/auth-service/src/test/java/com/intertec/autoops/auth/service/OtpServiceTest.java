package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.domain.OtpEntry;
import com.intertec.autoops.auth.exception.AuthException;
import com.intertec.autoops.auth.repo.OtpRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.context.annotation.Import;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * OTP attempt counting and lockout with REAL transaction semantics (see
 * RefreshTokenServiceTest for why NOT_SUPPORTED matters): the attempts
 * increment used to be rolled back by the thrown AuthException, so the
 * lockout could never engage.
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Import({OtpService.class, AuditService.class})
@EnableConfigurationProperties(AuthProperties.class)
@Transactional(propagation = Propagation.NOT_SUPPORTED)
class OtpServiceTest {

    private static final String EMAIL = "alice@example.com";
    private static final String TENANT = "tenant-a";
    private static final String GOOD_OTP = "123456";

    @Autowired
    private OtpService otpService;
    @Autowired
    private OtpRepository otpRepository;

    @BeforeEach
    void setUp() {
        otpRepository.deleteAll();
        // Seed a known challenge directly (plaintext OTPs are never persisted,
        // so tests hash their own).
        OtpEntry entry = new OtpEntry();
        entry.setEmail(EMAIL);
        entry.setTenantId(TENANT);
        entry.setOtpHash(OtpService.sha256Hex(GOOD_OTP));
        entry.setAttempts(0);
        entry.setMaxAttempts(3);
        entry.setExpiresAt(Instant.now().plusSeconds(300));
        otpRepository.save(entry);
    }

    private OtpEntry current() {
        return otpRepository
                .findTopByEmailAndTenantIdAndConsumedAtIsNullOrderByCreatedAtDesc(EMAIL, TENANT)
                .orElseThrow();
    }

    @Test
    void failedAttemptIsPersistedDespiteException() {
        AuthException ex = assertThrows(AuthException.class,
                () -> otpService.verify(EMAIL, TENANT, "000000", "1.2.3.4"));
        assertEquals("otp_invalid", ex.getError());
        // The increment must survive the exception (used to be rolled back).
        assertEquals(1, current().getAttempts());
    }

    @Test
    void lockoutEngagesAtMaxAttemptsAndPersists() {
        for (int i = 0; i < 3; i++) {
            assertThrows(AuthException.class,
                    () -> otpService.verify(EMAIL, TENANT, "000000", "1.2.3.4"));
        }
        OtpEntry entry = current();
        assertEquals(3, entry.getAttempts());
        assertNotNull(entry.getLockedAt(), "lockout must persist at max attempts");

        // Even the CORRECT code is rejected once locked.
        AuthException ex = assertThrows(AuthException.class,
                () -> otpService.verify(EMAIL, TENANT, GOOD_OTP, "1.2.3.4"));
        assertEquals("otp_locked", ex.getError());
    }

    @Test
    void correctOtpConsumesEntry() {
        otpService.verify(EMAIL, TENANT, GOOD_OTP, "1.2.3.4");
        assertNull(otpRepository
                .findTopByEmailAndTenantIdAndConsumedAtIsNullOrderByCreatedAtDesc(EMAIL, TENANT)
                .orElse(null), "consumed OTP must not be reusable");
    }

    @Test
    void expiredOtpIsRejectedWithoutCountingAttempts() {
        OtpEntry entry = current();
        entry.setExpiresAt(Instant.now().minusSeconds(1));
        otpRepository.save(entry);

        AuthException ex = assertThrows(AuthException.class,
                () -> otpService.verify(EMAIL, TENANT, GOOD_OTP, "1.2.3.4"));
        assertEquals("otp_expired", ex.getError());
        assertEquals(0, current().getAttempts());
    }
}
