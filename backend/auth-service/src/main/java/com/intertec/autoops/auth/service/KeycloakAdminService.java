package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.exception.AuthException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.context.annotation.Lazy;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.http.MediaType;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtException;
import org.springframework.stereotype.Service;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestClient;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Duration;
import java.util.Base64;
import java.util.Map;

/**
 * Keycloak OIDC authorization-code flow with login-CSRF protection.
 *
 * <ul>
 *   <li><strong>state</strong> is generated server-side, stored single-use in
 *       Redis (5 min TTL) and verified + consumed on callback — a callback
 *       whose state we did not issue (or that was already used) is rejected.</li>
 *   <li><strong>PKCE (S256)</strong>: the code_verifier is stored under the
 *       state and sent in the token exchange, so an attacker-supplied
 *       authorization code cannot be injected into a victim's flow.</li>
 * </ul>
 */
@Service
public class KeycloakAdminService {

    private static final Logger log = LoggerFactory.getLogger(KeycloakAdminService.class);
    private static final String STATE_KEY_PREFIX = "auth:sso-state:";
    private static final Duration STATE_TTL = Duration.ofMinutes(5);
    private static final SecureRandom RANDOM = new SecureRandom();

    private final RestClient keycloakRestClient;
    private final JwtDecoder keycloakJwtDecoder;
    private final StringRedisTemplate redisTemplate;
    private final AuthProperties properties;

    // @Lazy injection points: the Keycloak beans resolve issuer metadata over
    // HTTP on first use — proxies here let the service boot with Keycloak
    // down/unconfigured (SSO then fails at call time, not at startup).
    public KeycloakAdminService(
            @Qualifier("keycloakRestClient") @Lazy RestClient keycloakRestClient,
            @Qualifier("keycloakJwtDecoder") @Lazy JwtDecoder keycloakJwtDecoder,
            StringRedisTemplate redisTemplate,
            AuthProperties properties) {
        this.keycloakRestClient = keycloakRestClient;
        this.keycloakJwtDecoder = keycloakJwtDecoder;
        this.redisTemplate = redisTemplate;
        this.properties = properties;
    }

    /** Builds the redirect URL with a server-generated state + PKCE challenge. */
    public String buildAuthorizeUrl() {
        String state = randomToken(32);
        String codeVerifier = randomToken(48);
        storeState(state, codeVerifier);

        String codeChallenge = base64Url(sha256(codeVerifier.getBytes(StandardCharsets.US_ASCII)));
        AuthProperties.Keycloak keycloak = properties.getKeycloak();
        return keycloak.getIssuerUri() + "/protocol/openid-connect/auth"
                + "?client_id=" + encode(keycloak.getClientId())
                + "&redirect_uri=" + encode(keycloak.getRedirectUri())
                + "&response_type=code"
                + "&scope=" + encode("openid email profile")
                + "&state=" + encode(state)
                + "&code_challenge=" + encode(codeChallenge)
                + "&code_challenge_method=S256";
    }

    /** Verifies + consumes the state, then exchanges the code (with PKCE verifier). */
    public Jwt exchangeCodeForIdToken(String code, String state) {
        String codeVerifier = consumeState(state);
        AuthProperties.Keycloak keycloak = properties.getKeycloak();

        MultiValueMap<String, String> form = new LinkedMultiValueMap<>();
        form.add("grant_type", "authorization_code");
        form.add("code", code);
        form.add("redirect_uri", keycloak.getRedirectUri());
        form.add("client_id", keycloak.getClientId());
        form.add("client_secret", keycloak.getClientSecret());
        form.add("code_verifier", codeVerifier);

        Map<String, Object> response;
        try {
            response = keycloakRestClient.post()
                    .uri("/protocol/openid-connect/token")
                    .contentType(MediaType.APPLICATION_FORM_URLENCODED)
                    .body(form)
                    .retrieve()
                    .body(new ParameterizedTypeReference<Map<String, Object>>() {
                    });
        } catch (Exception ex) {
            log.warn("Keycloak token exchange failed: {}", ex.getMessage());
            throw AuthException.unauthorized("sso_failed", "SSO code exchange failed");
        }

        Object idToken = response != null ? response.get("id_token") : null;
        if (idToken == null) {
            throw AuthException.unauthorized("sso_failed", "SSO provider returned no identity token");
        }
        try {
            return keycloakJwtDecoder.decode(idToken.toString());
        } catch (JwtException ex) {
            throw AuthException.unauthorized("sso_failed", "SSO identity token is invalid");
        }
    }

    // ------------------------------------------------------------------

    private void storeState(String state, String codeVerifier) {
        try {
            redisTemplate.opsForValue().set(STATE_KEY_PREFIX + state, codeVerifier, STATE_TTL);
        } catch (Exception ex) {
            // Fail closed: without a stored state, the callback cannot be validated.
            log.error("Unable to store SSO state: {}", ex.getMessage());
            throw AuthException.serviceUnavailable("sso_unavailable",
                    "SSO is temporarily unavailable");
        }
    }

    private String consumeState(String state) {
        if (state == null || state.isBlank()) {
            throw AuthException.unauthorized("sso_state_invalid", "Missing SSO state");
        }
        String codeVerifier;
        try {
            // Single use: GETDEL prevents replay of a captured callback URL.
            codeVerifier = redisTemplate.opsForValue().getAndDelete(STATE_KEY_PREFIX + state);
        } catch (Exception ex) {
            log.error("Unable to read SSO state: {}", ex.getMessage());
            throw AuthException.serviceUnavailable("sso_unavailable",
                    "SSO is temporarily unavailable");
        }
        if (codeVerifier == null) {
            throw AuthException.unauthorized("sso_state_invalid",
                    "Invalid, expired, or already-used SSO state");
        }
        return codeVerifier;
    }

    private String randomToken(int byteLength) {
        byte[] bytes = new byte[byteLength];
        RANDOM.nextBytes(bytes);
        return base64Url(bytes);
    }

    private static String base64Url(byte[] bytes) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private static byte[] sha256(byte[] input) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(input);
        } catch (Exception ex) {
            throw new IllegalStateException("SHA-256 unavailable", ex);
        }
    }

    private String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }
}
