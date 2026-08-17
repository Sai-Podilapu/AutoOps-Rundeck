package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.client.SubscriptionServiceClient;
import com.intertec.autoops.auth.domain.ApiKey;
import com.intertec.autoops.auth.domain.AuditEventType;
import com.intertec.autoops.auth.domain.User;
import com.intertec.autoops.auth.domain.UserStatus;
import com.intertec.autoops.auth.exception.AuthException;
import com.intertec.autoops.auth.repo.ApiKeyRepository;
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

/**
 * Machine credentials for the API_ACCESS plan feature (Team+). A key is
 * minted once ({@code ak_<prefix>_<secret>}), stored only as a SHA-256 hash,
 * and exchanged for a SHORT-LIVED access token at /api/auth/token/api-key —
 * so downstream services keep validating exactly one credential type (RS256
 * access tokens) and revoking a key cuts new exchanges immediately.
 */
@Service
public class ApiKeyService {

    private static final Logger log = LoggerFactory.getLogger(ApiKeyService.class);
    private static final SecureRandom RANDOM = new SecureRandom();

    private final ApiKeyRepository apiKeyRepository;
    private final UserService userService;
    private final JwtService jwtService;
    private final SubscriptionServiceClient subscriptionServiceClient;
    private final AuditService auditService;

    public ApiKeyService(ApiKeyRepository apiKeyRepository, UserService userService,
                         JwtService jwtService,
                         SubscriptionServiceClient subscriptionServiceClient,
                         AuditService auditService) {
        this.apiKeyRepository = apiKeyRepository;
        this.userService = userService;
        this.jwtService = jwtService;
        this.subscriptionServiceClient = subscriptionServiceClient;
        this.auditService = auditService;
    }

    @Transactional(readOnly = true)
    public List<ApiKey> list(String tenantId) {
        return apiKeyRepository.findByTenantIdAndRevokedAtIsNullOrderByCreatedAtDesc(tenantId);
    }

    public record CreatedKey(ApiKey record, String rawKey) {
    }

    @Transactional
    public CreatedKey create(String tenantId, Long userId, String accessToken, String name) {
        var entitlement = subscriptionServiceClient.checkEntitlement(accessToken, tenantId,
                "API_ACCESS");
        if (!entitlement.entitled()) {
            throw AuthException.forbidden(
                    entitlement.reason().isBlank() ? "feature_not_in_plan" : entitlement.reason(),
                    "API access is not included in your plan — upgrade to unlock it");
        }
        if (name == null || name.isBlank() || name.length() > 128) {
            throw AuthException.badRequest("invalid_name", "Give the key a short name");
        }
        String secret = randomToken(32);
        String prefix = "ak_" + randomToken(6).substring(0, 8);
        String rawKey = prefix + "_" + secret;

        ApiKey key = new ApiKey();
        key.setTenantId(tenantId);
        key.setUserId(userId);
        key.setName(name.trim());
        key.setPrefix(prefix.length() > 12 ? prefix.substring(0, 12) : prefix);
        key.setKeyHash(sha256(rawKey));
        ApiKey saved = apiKeyRepository.save(key);
        auditService.record(AuditEventType.API_KEY_CREATED, userId, null, tenantId,
                null, null, null, "key " + saved.getPrefix() + " ('" + saved.getName() + "')");
        log.info("Tenant {} created API key {} ({})", tenantId, saved.getId(), saved.getPrefix());
        return new CreatedKey(saved, rawKey);
    }

    @Transactional
    public void revoke(String tenantId, Long actorUserId, Long id) {
        ApiKey key = apiKeyRepository.findByIdAndTenantId(id, tenantId)
                .orElseThrow(() -> AuthException.notFound("key_not_found", "No such API key"));
        if (key.getRevokedAt() == null) {
            key.setRevokedAt(Instant.now());
            apiKeyRepository.save(key);
            auditService.record(AuditEventType.API_KEY_REVOKED, actorUserId, null, tenantId,
                    null, null, null, "key " + key.getPrefix());
        }
    }

    public record ExchangeResult(String accessToken, long expiresIn) {
    }

    /** Key → short-lived access token; the key itself never hits other services. */
    @Transactional
    public ExchangeResult exchange(String rawKey) {
        if (rawKey == null || rawKey.isBlank()) {
            throw AuthException.unauthorized("invalid_api_key", "API key required");
        }
        ApiKey key = apiKeyRepository.findByKeyHashAndRevokedAtIsNull(sha256(rawKey.trim()))
                .orElseThrow(() -> AuthException.unauthorized("invalid_api_key",
                        "Unknown or revoked API key"));
        User user = userService.requireById(key.getUserId());
        if (user.getStatus() != UserStatus.ACTIVE) {
            throw AuthException.unauthorized("invalid_api_key",
                    "The key's owning account is not active");
        }
        key.setLastUsedAt(Instant.now());
        apiKeyRepository.save(key);
        return new ExchangeResult(jwtService.mintAccessToken(user),
                jwtService.accessTokenTtlSeconds());
    }

    private static String randomToken(int bytes) {
        byte[] buffer = new byte[bytes];
        RANDOM.nextBytes(buffer);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(buffer);
    }

    private static String sha256(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder(64);
            for (byte b : digest) {
                hex.append(Character.forDigit((b >> 4) & 0xF, 16))
                        .append(Character.forDigit(b & 0xF, 16));
            }
            return hex.toString();
        } catch (Exception ex) {
            throw new IllegalStateException("SHA-256 unavailable", ex);
        }
    }
}
