package com.intertec.autoops.auth.web;

import com.intertec.autoops.auth.exception.AuthException;
import com.intertec.autoops.auth.facade.AuthFacade;
import com.intertec.autoops.auth.security.IpResolver;
import com.intertec.autoops.auth.service.EnterpriseSsoService;
import com.intertec.autoops.auth.web.dto.IdpConfigRequest;
import com.intertec.autoops.auth.web.dto.IdpConfigResponse;
import com.intertec.autoops.auth.web.dto.TokenResponse;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/**
 * Enterprise per-tenant SSO: admins register THEIR OWN IdP (Enterprise-plan
 * entitlement enforced in the facade); the public endpoints drive login-page
 * domain routing and the OIDC round-trip against that IdP.
 */
@RestController
@RequestMapping("/api/auth/enterprise-sso")
public class EnterpriseSsoController {

    private final AuthFacade authFacade;
    private final EnterpriseSsoService enterpriseSsoService;
    private final IpResolver ipResolver;
    private final com.intertec.autoops.auth.config.AuthProperties properties;

    public EnterpriseSsoController(AuthFacade authFacade,
                                   EnterpriseSsoService enterpriseSsoService,
                                   IpResolver ipResolver,
                                   com.intertec.autoops.auth.config.AuthProperties properties) {
        this.authFacade = authFacade;
        this.enterpriseSsoService = enterpriseSsoService;
        this.ipResolver = ipResolver;
        this.properties = properties;
    }

    // ------ admin configuration (authenticated) ------

    @GetMapping("/config")
    public ResponseEntity<?> getConfig(@AuthenticationPrincipal Jwt jwt) {
        requireAdmin(jwt);
        return enterpriseSsoService.getConfig(jwt.getClaimAsString("tenantId"))
                .<ResponseEntity<?>>map(c -> ResponseEntity.ok(IdpConfigResponse.from(c)))
                .orElseGet(() -> ResponseEntity.ok(Map.of("configured", false)));
    }

    @PutMapping("/config")
    public IdpConfigResponse saveConfig(@Valid @RequestBody IdpConfigRequest request,
                                        @AuthenticationPrincipal Jwt jwt,
                                        HttpServletRequest httpRequest) {
        requireAdmin(jwt);
        Long userId = ((Number) jwt.getClaim("userId")).longValue();
        return IdpConfigResponse.from(authFacade.configureIdp(jwt.getTokenValue(),
                jwt.getClaimAsString("tenantId"), request.issuer(), request.clientId(),
                request.clientSecret(), request.emailDomains(), request.enforceSso(),
                request.authorizeUrl(), request.tokenUrl(), request.userinfoUrl(),
                userId, jwt.getSubject(), ipResolver.resolve(httpRequest),
                httpRequest.getHeader(HttpHeaders.USER_AGENT)));
    }

    @DeleteMapping("/config")
    public ResponseEntity<Void> deleteConfig(@AuthenticationPrincipal Jwt jwt) {
        requireAdmin(jwt);
        enterpriseSsoService.deleteConfig(jwt.getClaimAsString("tenantId"));
        return ResponseEntity.noContent().build();
    }

    // ------ public: login-page routing + OIDC round-trip ------

    /** Does this email's domain belong to an SSO-enabled workspace? */
    @GetMapping("/resolve")
    public Map<String, Object> resolve(@RequestParam String email) {
        return enterpriseSsoService.resolveByEmail(email)
                .<Map<String, Object>>map(c -> Map.of(
                        "ssoAvailable", true,
                        "ssoRequired", c.isEnforceSso()))
                .orElse(Map.of("ssoAvailable", false, "ssoRequired", false));
    }

    @GetMapping("/initiate")
    public ResponseEntity<Void> initiate(@RequestParam String email) {
        return ResponseEntity.status(HttpStatus.FOUND)
                .location(URI.create(authFacade.enterpriseInitiate(email)))
                .build();
    }

    @GetMapping("/callback")
    public ResponseEntity<?> callback(@RequestParam String code,
                                      @RequestParam String state,
                                      HttpServletRequest httpRequest) {
        TokenResponse tokens = authFacade.enterpriseCallback(code, state,
                ipResolver.resolve(httpRequest),
                httpRequest.getHeader(HttpHeaders.USER_AGENT));
        String redirect = properties.getKeycloak().getSuccessRedirect();
        if (redirect == null || redirect.isBlank()) {
            return ResponseEntity.ok(tokens);
        }
        String fragment = "accessToken=" + url(tokens.accessToken())
                + "&refreshToken=" + url(tokens.refreshToken())
                + "&tokenType=Bearer&expiresIn=" + tokens.expiresIn();
        return ResponseEntity.status(HttpStatus.FOUND)
                .location(URI.create(redirect + "#" + fragment))
                .build();
    }

    private void requireAdmin(Jwt jwt) {
        if (!"ADMIN".equals(jwt.getClaimAsString("role"))) {
            throw AuthException.forbidden("admin_required",
                    "Only workspace admins can manage SSO");
        }
    }

    private static String url(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }
}
