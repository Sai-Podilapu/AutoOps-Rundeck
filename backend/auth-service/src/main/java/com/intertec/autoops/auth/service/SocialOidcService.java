package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.exception.AuthException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Service;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestClient;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Duration;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Map;

/**
 * Direct social OIDC against Google and Microsoft (confidential-client
 * authorization-code flow). Identity comes from the provider's USERINFO
 * endpoint fetched server-side over TLS with the freshly exchanged access
 * token — no local id_token signature validation needed for that path.
 *
 * <p>CSRF: the state parameter is generated server-side, stored single-use in
 * Redis (5 min TTL), and consumed on the callback. Redis down = SSO down
 * (fail closed).
 */
@Service
public class SocialOidcService {

    private static final Logger log = LoggerFactory.getLogger(SocialOidcService.class);
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final String STATE_PREFIX = "auth:social-state:";
    private static final Duration STATE_TTL = Duration.ofMinutes(5);

    /** Fixed, public OIDC endpoints per provider. */
    private record Endpoints(String authorize, String token, String userinfo) {
    }

    private static final Map<String, Endpoints> PROVIDERS = Map.of(
            "google", new Endpoints(
                    "https://accounts.google.com/o/oauth2/v2/auth",
                    "https://oauth2.googleapis.com/token",
                    "https://openidconnect.googleapis.com/v1/userinfo"),
            "microsoft", new Endpoints(
                    "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
                    "https://login.microsoftonline.com/common/oauth2/v2.0/token",
                    "https://graph.microsoft.com/oidc/userinfo"));

    public record SocialIdentity(String provider, String subject, String email, String fullName) {
    }

    private final AuthProperties properties;
    private final StringRedisTemplate redisTemplate;
    private final RestClient restClient;

    public SocialOidcService(AuthProperties properties, StringRedisTemplate redisTemplate) {
        this.properties = properties;
        this.redisTemplate = redisTemplate;
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(3000);
        requestFactory.setReadTimeout(5000);
        this.restClient = RestClient.builder().requestFactory(requestFactory).build();
    }

    public String buildAuthorizeUrl(String provider) {
        Endpoints endpoints = endpoints(provider);
        AuthProperties.Social.Provider config = config(provider);

        byte[] stateBytes = new byte[24];
        RANDOM.nextBytes(stateBytes);
        String state = HexFormat.of().formatHex(stateBytes);
        redisTemplate.opsForValue().set(STATE_PREFIX + state, provider, STATE_TTL);

        return endpoints.authorize()
                + "?response_type=code"
                + "&client_id=" + url(config.getClientId())
                + "&redirect_uri=" + url(redirectUri(provider))
                + "&scope=" + url("openid email profile")
                + "&state=" + state
                + "&prompt=select_account";
    }

    public SocialIdentity handleCallback(String provider, String code, String state) {
        Endpoints endpoints = endpoints(provider);
        AuthProperties.Social.Provider config = config(provider);
        consumeState(provider, state);

        Map<String, Object> tokens = exchangeCode(endpoints, config, provider, code);
        Object accessToken = tokens.get("access_token");
        if (accessToken == null) {
            throw AuthException.unauthorized("sso_failed", "Provider returned no access token");
        }

        Map<String, Object> userinfo = fetchUserinfo(endpoints, accessToken.toString());
        String subject = str(userinfo.get("sub"));
        String email = str(userinfo.get("email"));
        if (email == null || !email.contains("@")) {
            // Microsoft personal accounts may expose the address differently.
            String preferred = str(userinfo.get("preferred_username"));
            email = preferred != null && preferred.contains("@") ? preferred : null;
        }
        return new SocialIdentity(provider, subject, email, str(userinfo.get("name")));
    }

    // ------------------------------------------------------------------

    private void consumeState(String provider, String state) {
        if (state == null || state.isBlank()) {
            throw AuthException.unauthorized("sso_failed", "Missing state");
        }
        String stored;
        try {
            stored = redisTemplate.opsForValue().getAndDelete(STATE_PREFIX + state);
        } catch (Exception ex) {
            log.error("SSO state store unavailable: {}", ex.getMessage());
            throw AuthException.serviceUnavailable("sso_unavailable",
                    "Sign-in is temporarily unavailable — please retry");
        }
        if (!provider.equals(stored)) {
            throw AuthException.unauthorized("sso_failed", "Invalid or expired sign-in attempt");
        }
    }

    private Map<String, Object> exchangeCode(Endpoints endpoints,
                                             AuthProperties.Social.Provider config,
                                             String provider, String code) {
        MultiValueMap<String, String> form = new LinkedMultiValueMap<>();
        form.add("grant_type", "authorization_code");
        form.add("code", code);
        form.add("client_id", config.getClientId());
        form.add("client_secret", config.getClientSecret());
        form.add("redirect_uri", redirectUri(provider));
        try {
            @SuppressWarnings("unchecked")
            Map<String, Object> response = restClient.post()
                    .uri(endpoints.token())
                    .contentType(MediaType.APPLICATION_FORM_URLENCODED)
                    .body(form)
                    .retrieve()
                    .body(Map.class);
            return response != null ? response : Map.of();
        } catch (Exception ex) {
            log.warn("Social code exchange failed ({}): {}", provider, ex.getMessage());
            throw AuthException.unauthorized("sso_failed", "Sign-in could not be completed");
        }
    }

    private Map<String, Object> fetchUserinfo(Endpoints endpoints, String accessToken) {
        try {
            @SuppressWarnings("unchecked")
            Map<String, Object> response = restClient.get()
                    .uri(endpoints.userinfo())
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                    .retrieve()
                    .body(Map.class);
            return response != null ? response : Map.of();
        } catch (Exception ex) {
            log.warn("Social userinfo fetch failed: {}", ex.getMessage());
            throw AuthException.unauthorized("sso_failed", "Sign-in could not be completed");
        }
    }

    private Endpoints endpoints(String provider) {
        Endpoints endpoints = PROVIDERS.get(provider == null
                ? "" : provider.toLowerCase(Locale.ROOT));
        if (endpoints == null) {
            throw AuthException.notFound("unknown_provider", "Unknown SSO provider");
        }
        return endpoints;
    }

    private AuthProperties.Social.Provider config(String provider) {
        AuthProperties.Social.Provider config = "google".equalsIgnoreCase(provider)
                ? properties.getSocial().getGoogle()
                : properties.getSocial().getMicrosoft();
        if (config.getClientId() == null || config.getClientId().isBlank()) {
            throw AuthException.serviceUnavailable("sso_not_configured",
                    "Sign-in with this provider is not configured");
        }
        return config;
    }

    private String redirectUri(String provider) {
        return properties.getSocial().getRedirectBaseUrl()
                + "/api/auth/sso/" + provider.toLowerCase(Locale.ROOT) + "/callback";
    }

    private static String url(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    private static String str(Object value) {
        return value != null ? value.toString() : null;
    }
}
