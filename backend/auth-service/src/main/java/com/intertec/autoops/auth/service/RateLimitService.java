package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.config.AuthProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

import java.util.Locale;

/**
 * Fixed-window rate limiting on Redis (INCR + expire on first hit).
 *
 * <p><strong>Failure semantics differ by path:</strong>
 * <ul>
 *   <li><strong>OTP generate: FAIL-OPEN.</strong> An infra outage should not
 *       stop code delivery; the abuse ceiling is preserved by the verify
 *       limiter below.</li>
 *   <li><strong>OTP verify: FAIL-CLOSED and keyed per-account only.</strong>
 *       Verification is the brute-force surface for a 6-digit code, so a
 *       Redis outage, IP rotation, or spoofed forwarding headers must never
 *       remove this cap. The key deliberately excludes the IP.</li>
 * </ul>
 */
@Service
public class RateLimitService {

    private static final Logger log = LoggerFactory.getLogger(RateLimitService.class);

    /** Per-IP generate limit = per-account limit x this factor (NAT-friendly). */
    private static final int IP_LIMIT_FACTOR = 20;

    private final StringRedisTemplate redisTemplate;
    private final AuthProperties properties;

    public RateLimitService(StringRedisTemplate redisTemplate, AuthProperties properties) {
        this.redisTemplate = redisTemplate;
        this.properties = properties;
    }

    public boolean allowOtpRequest(String email, String ipAddress) {
        int limit = properties.getRateLimit().getOtpRequests();
        boolean perAccount = allow("auth:rl:otp:" + normalize(email), limit, true);
        boolean perIp = allow("auth:rl:otp-ip:" + ipAddress, limit * IP_LIMIT_FACTOR, true);
        return perAccount && perIp;
    }

    /** Per-account, IP-independent, fail-closed (see class javadoc). */
    public boolean allowVerifyAttempt(String email, String ipAddress) {
        return allow("auth:rl:verify:" + normalize(email),
                properties.getRateLimit().getVerifyAttempts(), false);
    }

    /**
     * Password-login attempts: per-account + per-IP, FAIL-OPEN. Unlike a
     * 6-digit OTP, a password holds enough entropy that BCrypt cost plus this
     * limiter is the brake — an infra outage should not lock every user out.
     */
    public boolean allowPasswordLogin(String email, String ipAddress) {
        int limit = properties.getRateLimit().getLoginAttempts();
        boolean perAccount = allow("auth:rl:login:" + normalize(email), limit, true);
        boolean perIp = allow("auth:rl:login-ip:" + ipAddress, limit * IP_LIMIT_FACTOR, true);
        return perAccount && perIp;
    }

    /** Self-service registrations per IP, FAIL-OPEN (BCrypt-burn / mass-signup brake). */
    public boolean allowRegistration(String ipAddress) {
        return allow("auth:rl:register-ip:" + ipAddress,
                properties.getRateLimit().getRegistrations(), true);
    }

    /**
     * Short per-email mutex closing the register check-then-insert race: two
     * simultaneous sign-ups with the same email would otherwise both pass the
     * global uniqueness check (no cross-tenant unique index is possible —
     * admin onboarding legitimately reuses an email across tenants).
     * TTL-expired, never explicitly released; FAIL-OPEN on Redis outage.
     */
    public boolean tryRegisterLock(String email) {
        try {
            Boolean acquired = redisTemplate.opsForValue().setIfAbsent(
                    "auth:reg-lock:" + normalize(email), "1", java.time.Duration.ofSeconds(10));
            return !Boolean.FALSE.equals(acquired);
        } catch (Exception ex) {
            log.warn("Register lock unavailable (fail-open): {}", ex.getMessage());
            return true;
        }
    }

    private boolean allow(String key, int limit, boolean failOpen) {
        try {
            Long count = redisTemplate.opsForValue().increment(key);
            if (count != null && count == 1L) {
                redisTemplate.expire(key, properties.getRateLimit().getWindow());
            }
            return count == null || count <= limit;
        } catch (Exception ex) {
            if (failOpen) {
                log.warn("Rate limiter unavailable (fail-open) for {}: {}", key, ex.getMessage());
                return true;
            }
            log.error("Rate limiter unavailable (fail-closed) for {}: {}", key, ex.getMessage());
            return false;
        }
    }

    private String normalize(String email) {
        return email == null ? "" : email.trim().toLowerCase(Locale.ROOT);
    }
}
