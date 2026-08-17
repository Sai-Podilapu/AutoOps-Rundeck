package com.intertec.autoops.auth.config;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.jackson2.SecurityJackson2Modules;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.core.OAuth2AccessToken;
import org.springframework.security.oauth2.core.OAuth2Token;
import org.springframework.security.oauth2.server.authorization.JdbcOAuth2AuthorizationService;
import org.springframework.security.oauth2.server.authorization.OAuth2Authorization;
import org.springframework.security.oauth2.server.authorization.OAuth2AuthorizationService;
import org.springframework.security.oauth2.server.authorization.OAuth2TokenType;
import org.springframework.security.oauth2.server.authorization.client.RegisteredClient;
import org.springframework.security.oauth2.server.authorization.client.RegisteredClientRepository;
import org.springframework.security.oauth2.server.authorization.jackson2.OAuth2AuthorizationServerJackson2Module;
import org.springframework.util.Assert;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Selectable OAuth2Authorization store: autoops.auth.token-store = jdbc | redis.
 *
 * <ul>
 *   <li><strong>jdbc</strong> (default): SAS's JdbcOAuth2AuthorizationService over
 *       the oauth2_authorization table (V2 migration).</li>
 *   <li><strong>redis</strong>: JSON-serialized store (Jackson with the Spring
 *       Security / Authorization Server modules — the same serializer the JDBC
 *       service uses). No Java native serialization: nothing read from Redis
 *       ever reaches ObjectInputStream. Keys: {@code oauth2:authorization:{id}}
 *       plus a token-hash index {@code oauth2:token:{sha256hex}}. Supports the
 *       client_credentials authorizations this service issues (gateway
 *       introspection).</li>
 * </ul>
 */
@Configuration
public class TokenStoreConfig {

    @Bean
    @ConditionalOnProperty(name = "autoops.auth.token-store", havingValue = "jdbc", matchIfMissing = true)
    public OAuth2AuthorizationService jdbcAuthorizationService(JdbcTemplate jdbcTemplate,
                                                               RegisteredClientRepository registeredClientRepository) {
        return new JdbcOAuth2AuthorizationService(jdbcTemplate, registeredClientRepository);
    }

    @Bean
    @ConditionalOnProperty(name = "autoops.auth.token-store", havingValue = "redis")
    public OAuth2AuthorizationService redisAuthorizationService(StringRedisTemplate redisTemplate,
                                                                RegisteredClientRepository registeredClientRepository) {
        return new RedisOAuth2AuthorizationService(redisTemplate, registeredClientRepository);
    }

    /** Redis-backed OAuth2AuthorizationService (JSON, no native serialization). */
    static class RedisOAuth2AuthorizationService implements OAuth2AuthorizationService {

        private static final String AUTHORIZATION_KEY_PREFIX = "oauth2:authorization:";
        private static final String TOKEN_INDEX_KEY_PREFIX = "oauth2:token:";
        private static final Duration DEFAULT_TTL = Duration.ofHours(24);
        private static final Duration EXPIRY_GRACE = Duration.ofHours(1);

        private final StringRedisTemplate redisTemplate;
        private final RegisteredClientRepository registeredClientRepository;
        private final ObjectMapper objectMapper;

        RedisOAuth2AuthorizationService(StringRedisTemplate redisTemplate,
                                        RegisteredClientRepository registeredClientRepository) {
            this.redisTemplate = redisTemplate;
            this.registeredClientRepository = registeredClientRepository;
            // Same Jackson setup as JdbcOAuth2AuthorizationService: allow-listed
            // security types + default typing, so Instants and claim maps round-trip.
            ClassLoader classLoader = RedisOAuth2AuthorizationService.class.getClassLoader();
            this.objectMapper = new ObjectMapper();
            this.objectMapper.registerModules(SecurityJackson2Modules.getModules(classLoader));
            this.objectMapper.registerModule(new OAuth2AuthorizationServerJackson2Module());
        }

        @Override
        public void save(OAuth2Authorization authorization) {
            Assert.notNull(authorization, "authorization cannot be null");

            Map<String, Object> data = new HashMap<>();
            data.put("id", authorization.getId());
            data.put("registeredClientId", authorization.getRegisteredClientId());
            data.put("principalName", authorization.getPrincipalName());
            data.put("authorizationGrantType", authorization.getAuthorizationGrantType().getValue());
            data.put("authorizedScopes", new ArrayList<>(authorization.getAuthorizedScopes()));

            Duration ttl = DEFAULT_TTL;
            OAuth2Authorization.Token<? extends OAuth2Token> accessToken =
                    authorization.getAccessToken();
            if (accessToken != null) {
                OAuth2Token token = accessToken.getToken();
                data.put("accessTokenValue", token.getTokenValue());
                data.put("accessTokenIssuedAt", token.getIssuedAt());
                data.put("accessTokenExpiresAt", token.getExpiresAt());
                data.put("accessTokenMetadata", accessToken.getMetadata());
                if (token instanceof OAuth2AccessToken oauth2AccessToken) {
                    data.put("accessTokenScopes", new ArrayList<>(oauth2AccessToken.getScopes()));
                }
                if (token.getExpiresAt() != null) {
                    Duration untilExpiry = Duration.between(Instant.now(), token.getExpiresAt())
                            .plus(EXPIRY_GRACE);
                    ttl = untilExpiry.compareTo(Duration.ofMinutes(1)) > 0
                            ? untilExpiry
                            : Duration.ofMinutes(1);
                }
            }

            String json = serialize(data);
            redisTemplate.opsForValue().set(
                    AUTHORIZATION_KEY_PREFIX + authorization.getId(), json, ttl);
            if (accessToken != null) {
                redisTemplate.opsForValue().set(
                        tokenIndexKey(accessToken.getToken().getTokenValue()),
                        authorization.getId(), ttl);
            }
        }

        @Override
        public void remove(OAuth2Authorization authorization) {
            Assert.notNull(authorization, "authorization cannot be null");
            redisTemplate.delete(AUTHORIZATION_KEY_PREFIX + authorization.getId());
            OAuth2Authorization.Token<? extends OAuth2Token> accessToken =
                    authorization.getAccessToken();
            if (accessToken != null) {
                redisTemplate.delete(tokenIndexKey(accessToken.getToken().getTokenValue()));
            }
        }

        @Override
        public OAuth2Authorization findById(String id) {
            Assert.hasText(id, "id cannot be empty");
            String json = redisTemplate.opsForValue().get(AUTHORIZATION_KEY_PREFIX + id);
            return json != null ? deserialize(json) : null;
        }

        @Override
        public OAuth2Authorization findByToken(String token, OAuth2TokenType tokenType) {
            Assert.hasText(token, "token cannot be empty");
            String id = redisTemplate.opsForValue().get(tokenIndexKey(token));
            return id != null ? findById(id) : null;
        }

        // ------------------------------------------------------------------

        private String serialize(Map<String, Object> data) {
            try {
                return objectMapper.writeValueAsString(data);
            } catch (Exception ex) {
                throw new IllegalStateException("Unable to serialize OAuth2Authorization", ex);
            }
        }

        @SuppressWarnings("unchecked")
        private OAuth2Authorization deserialize(String json) {
            Map<String, Object> data;
            try {
                data = objectMapper.readValue(json, new TypeReference<Map<String, Object>>() {
                });
            } catch (Exception ex) {
                throw new IllegalStateException("Unable to deserialize OAuth2Authorization", ex);
            }

            RegisteredClient registeredClient = registeredClientRepository
                    .findById((String) data.get("registeredClientId"));
            if (registeredClient == null) {
                return null;
            }

            Set<String> authorizedScopes = new HashSet<>(
                    (Collection<String>) data.getOrDefault("authorizedScopes", List.of()));
            OAuth2Authorization.Builder builder = OAuth2Authorization
                    .withRegisteredClient(registeredClient)
                    .id((String) data.get("id"))
                    .principalName((String) data.get("principalName"))
                    .authorizationGrantType(new AuthorizationGrantType(
                            (String) data.get("authorizationGrantType")))
                    .authorizedScopes(authorizedScopes);

            String accessTokenValue = (String) data.get("accessTokenValue");
            if (accessTokenValue != null) {
                Set<String> tokenScopes = new HashSet<>(
                        (Collection<String>) data.getOrDefault("accessTokenScopes", List.of()));
                OAuth2AccessToken accessToken = new OAuth2AccessToken(
                        OAuth2AccessToken.TokenType.BEARER,
                        accessTokenValue,
                        (Instant) data.get("accessTokenIssuedAt"),
                        (Instant) data.get("accessTokenExpiresAt"),
                        tokenScopes);
                Map<String, Object> metadata = (Map<String, Object>) data
                        .getOrDefault("accessTokenMetadata", Map.of());
                builder.token(accessToken, existing -> existing.putAll(metadata));
            }

            return builder.build();
        }

        private String tokenIndexKey(String tokenValue) {
            return TOKEN_INDEX_KEY_PREFIX + sha256Hex(tokenValue);
        }

        private static String sha256Hex(String value) {
            try {
                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                return HexFormat.of().formatHex(digest.digest(value.getBytes(StandardCharsets.UTF_8)));
            } catch (Exception ex) {
                throw new IllegalStateException("SHA-256 unavailable", ex);
            }
        }
    }
}
