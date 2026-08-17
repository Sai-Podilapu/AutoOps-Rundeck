package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.domain.TenantIdpConfig;
import com.intertec.autoops.auth.exception.AuthException;
import com.intertec.autoops.auth.repo.TenantIdpConfigRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestClient;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Duration;
import java.util.Collection;
import java.util.HexFormat;
import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

/**
 * Per-tenant OIDC against the TENANT's own identity provider (Okta, Azure AD,
 * Google Workspace, Keycloak, ...) — the Enterprise "SSO" feature. Same
 * confidential-client code flow + server-side USERINFO as social login, but
 * every endpoint/credential comes from the tenant's stored configuration.
 *
 * <p>State is single-use in Redis (5 min TTL) and maps back to the tenant, so
 * the callback knows whose IdP answered. Saving a config with blank endpoint
 * URLs fills them from the issuer's {@code /.well-known/openid-configuration}.
 */
@Service
public class EnterpriseSsoService {

    private static final Logger log = LoggerFactory.getLogger(EnterpriseSsoService.class);
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final String STATE_PREFIX = "auth:esso-state:";
    private static final Duration STATE_TTL = Duration.ofMinutes(5);

    public record IdpIdentity(String tenantId, String subject, String email, String fullName) {
    }

    private final TenantIdpConfigRepository configRepository;
    private final StringRedisTemplate redisTemplate;
    private final AuthProperties properties;
    private final RestClient restClient;

    public EnterpriseSsoService(TenantIdpConfigRepository configRepository,
                                StringRedisTemplate redisTemplate,
                                AuthProperties properties) {
        this.configRepository = configRepository;
        this.redisTemplate = redisTemplate;
        this.properties = properties;
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(3000);
        requestFactory.setReadTimeout(5000);
        this.restClient = RestClient.builder().requestFactory(requestFactory).build();
    }

    // ------------------------------------------------------------------
    // Configuration (entitlement-gated by the caller)
    // ------------------------------------------------------------------

    @Transactional(readOnly = true)
    public Optional<TenantIdpConfig> getConfig(String tenantId) {
        return configRepository.findById(tenantId);
    }

    @Transactional
    public TenantIdpConfig saveConfig(String tenantId, String issuer, String clientId,
                                      String clientSecret, Collection<String> emailDomains,
                                      boolean enforceSso, String authorizeUrl, String tokenUrl,
                                      String userinfoUrl) {
        Set<String> domains = normalizeDomains(emailDomains);
        for (String domain : domains) {
            configRepository.findByDomain(domain).ifPresent(owner -> {
                if (!owner.getTenantId().equals(tenantId)) {
                    throw AuthException.conflict("domain_taken",
                            "The domain " + domain + " is already claimed by another workspace");
                }
            });
        }

        TenantIdpConfig config = configRepository.findById(tenantId)
                .orElseGet(TenantIdpConfig::new);
        config.setTenantId(tenantId);
        config.setIssuer(issuer.trim());
        config.setClientId(clientId.trim());
        if (clientSecret != null && !clientSecret.isBlank()) {
            config.setClientSecret(clientSecret.trim()); // omit to keep the stored one
        } else if (config.getClientSecret() == null) {
            throw AuthException.badRequest("missing_secret", "clientSecret is required");
        }
        config.setEnforceSso(enforceSso);
        config.setEnabled(true);
        config.setEmailDomains(domains);

        if (isBlank(authorizeUrl) || isBlank(tokenUrl) || isBlank(userinfoUrl)) {
            fillFromDiscovery(config);
        } else {
            config.setAuthorizeUrl(authorizeUrl.trim());
            config.setTokenUrl(tokenUrl.trim());
            config.setUserinfoUrl(userinfoUrl.trim());
        }
        return configRepository.save(config);
    }

    @Transactional
    public void deleteConfig(String tenantId) {
        configRepository.deleteById(tenantId);
    }

    // ------------------------------------------------------------------
    // Login-time routing + code flow
    // ------------------------------------------------------------------

    /** The active IdP config owning this email's domain, if any. */
    @Transactional(readOnly = true)
    public Optional<TenantIdpConfig> resolveByEmail(String email) {
        String domain = domainOf(email);
        if (domain == null) {
            return Optional.empty();
        }
        return configRepository.findByDomain(domain).filter(TenantIdpConfig::isEnabled);
    }

    /** True when the tenant enforces SSO for members (admins keep break-glass). */
    @Transactional(readOnly = true)
    public boolean enforced(String tenantId) {
        return configRepository.findById(tenantId)
                .map(c -> c.isEnabled() && c.isEnforceSso())
                .orElse(false);
    }

    public String buildAuthorizeUrl(TenantIdpConfig config) {
        byte[] stateBytes = new byte[24];
        RANDOM.nextBytes(stateBytes);
        String state = HexFormat.of().formatHex(stateBytes);
        redisTemplate.opsForValue().set(STATE_PREFIX + state, config.getTenantId(), STATE_TTL);

        return config.getAuthorizeUrl()
                + "?response_type=code"
                + "&client_id=" + url(config.getClientId())
                + "&redirect_uri=" + url(redirectUri())
                + "&scope=" + url("openid email profile")
                + "&state=" + state;
    }

    @Transactional(readOnly = true)
    public IdpIdentity handleCallback(String code, String state) {
        String tenantId = consumeState(state);
        TenantIdpConfig config = configRepository.findById(tenantId)
                .filter(TenantIdpConfig::isEnabled)
                .orElseThrow(() -> AuthException.unauthorized("sso_failed",
                        "SSO is no longer configured for this workspace"));

        Map<String, Object> tokens = exchangeCode(config, code);
        Object accessToken = tokens.get("access_token");
        if (accessToken == null) {
            throw AuthException.unauthorized("sso_failed", "Provider returned no access token");
        }
        Map<String, Object> userinfo = fetchUserinfo(config, accessToken.toString());
        String email = str(userinfo.get("email"));
        if (email == null || !email.contains("@")) {
            String preferred = str(userinfo.get("preferred_username"));
            email = preferred != null && preferred.contains("@") ? preferred : null;
        }
        return new IdpIdentity(tenantId, str(userinfo.get("sub")), email,
                str(userinfo.get("name")));
    }

    // ------------------------------------------------------------------

    private void fillFromDiscovery(TenantIdpConfig config) {
        String discoveryUrl = config.getIssuer().replaceAll("/+$", "")
                + "/.well-known/openid-configuration";
        try {
            @SuppressWarnings("unchecked")
            Map<String, Object> discovery = restClient.get()
                    .uri(discoveryUrl)
                    .retrieve()
                    .body(Map.class);
            if (discovery == null) {
                throw new IllegalStateException("empty discovery document");
            }
            config.setAuthorizeUrl(str(discovery.get("authorization_endpoint")));
            config.setTokenUrl(str(discovery.get("token_endpoint")));
            config.setUserinfoUrl(str(discovery.get("userinfo_endpoint")));
            if (isBlank(config.getAuthorizeUrl()) || isBlank(config.getTokenUrl())
                    || isBlank(config.getUserinfoUrl())) {
                throw new IllegalStateException("discovery document is missing endpoints");
            }
        } catch (AuthException ex) {
            throw ex;
        } catch (Exception ex) {
            log.warn("OIDC discovery failed for {}: {}", discoveryUrl, ex.getMessage());
            throw AuthException.badRequest("discovery_failed",
                    "Could not read " + discoveryUrl + " — provide the endpoint URLs explicitly");
        }
    }

    private String consumeState(String state) {
        if (state == null || state.isBlank()) {
            throw AuthException.unauthorized("sso_failed", "Missing state");
        }
        String tenantId;
        try {
            tenantId = redisTemplate.opsForValue().getAndDelete(STATE_PREFIX + state);
        } catch (Exception ex) {
            log.error("SSO state store unavailable: {}", ex.getMessage());
            throw AuthException.serviceUnavailable("sso_unavailable",
                    "Sign-in is temporarily unavailable — please retry");
        }
        if (tenantId == null) {
            throw AuthException.unauthorized("sso_failed", "Invalid or expired sign-in attempt");
        }
        return tenantId;
    }

    private Map<String, Object> exchangeCode(TenantIdpConfig config, String code) {
        MultiValueMap<String, String> form = new LinkedMultiValueMap<>();
        form.add("grant_type", "authorization_code");
        form.add("code", code);
        form.add("client_id", config.getClientId());
        form.add("client_secret", config.getClientSecret());
        form.add("redirect_uri", redirectUri());
        try {
            @SuppressWarnings("unchecked")
            Map<String, Object> response = restClient.post()
                    .uri(config.getTokenUrl())
                    .contentType(MediaType.APPLICATION_FORM_URLENCODED)
                    .body(form)
                    .retrieve()
                    .body(Map.class);
            return response != null ? response : Map.of();
        } catch (Exception ex) {
            log.warn("Enterprise code exchange failed (tenant {}): {}",
                    config.getTenantId(), ex.getMessage());
            throw AuthException.unauthorized("sso_failed", "Sign-in could not be completed");
        }
    }

    private Map<String, Object> fetchUserinfo(TenantIdpConfig config, String accessToken) {
        try {
            @SuppressWarnings("unchecked")
            Map<String, Object> response = restClient.get()
                    .uri(config.getUserinfoUrl())
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                    .retrieve()
                    .body(Map.class);
            return response != null ? response : Map.of();
        } catch (Exception ex) {
            log.warn("Enterprise userinfo fetch failed: {}", ex.getMessage());
            throw AuthException.unauthorized("sso_failed", "Sign-in could not be completed");
        }
    }

    private String redirectUri() {
        return properties.getSocial().getRedirectBaseUrl() + "/api/auth/enterprise-sso/callback";
    }

    private Set<String> normalizeDomains(Collection<String> domains) {
        Set<String> normalized = new LinkedHashSet<>();
        if (domains != null) {
            for (String domain : domains) {
                if (domain != null && !domain.isBlank()) {
                    normalized.add(domain.trim().toLowerCase(Locale.ROOT).replaceFirst("^@", ""));
                }
            }
        }
        if (normalized.isEmpty()) {
            throw AuthException.badRequest("missing_domains",
                    "At least one email domain is required");
        }
        return normalized;
    }

    private static String domainOf(String email) {
        if (email == null) {
            return null;
        }
        int at = email.lastIndexOf('@');
        return at > 0 && at < email.length() - 1
                ? email.substring(at + 1).trim().toLowerCase(Locale.ROOT)
                : null;
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    private static String url(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    private static String str(Object value) {
        return value != null ? value.toString() : null;
    }
}
