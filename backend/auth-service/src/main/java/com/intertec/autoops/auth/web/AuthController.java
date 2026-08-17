package com.intertec.autoops.auth.web;

import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.domain.User;
import com.intertec.autoops.auth.facade.AuthFacade;
import com.intertec.autoops.auth.security.GatewayAuthGuard;
import com.intertec.autoops.auth.security.IpResolver;
import com.intertec.autoops.auth.exception.AuthException;
import com.intertec.autoops.auth.security.TenantContext;
import com.intertec.autoops.auth.service.UserService;
import com.intertec.autoops.auth.service.WorkspaceService;
import com.intertec.autoops.auth.web.dto.AuthorizeRequest;
import com.intertec.autoops.auth.web.dto.AuthorizeResponse;
import com.intertec.autoops.auth.web.dto.ChangePasswordRequest;
import com.intertec.autoops.auth.web.dto.LoginRequest;
import com.intertec.autoops.auth.web.dto.OnboardRequest;
import com.intertec.autoops.auth.web.dto.OtpGenerateRequest;
import com.intertec.autoops.auth.web.dto.OtpVerifyRequest;
import com.intertec.autoops.auth.web.dto.RefreshRequest;
import com.intertec.autoops.auth.web.dto.RegisterRequest;
import com.intertec.autoops.auth.web.dto.ResetPasswordRequest;
import com.intertec.autoops.auth.web.dto.RoleUpdateRequest;
import com.intertec.autoops.auth.web.dto.TokenResponse;
import com.intertec.autoops.auth.web.dto.UserProfileResponse;
import com.intertec.autoops.auth.web.dto.WorkspaceUpdateRequest;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/**
 * Public auth API. Thin layer: resolves tenant/IP/user-agent context and
 * delegates every use case to {@link AuthFacade}.
 */
@RestController
@RequestMapping("/api/auth")
public class AuthController {

    private final AuthFacade authFacade;
    private final UserService userService;
    private final WorkspaceService workspaceService;
    private final IpResolver ipResolver;
    private final GatewayAuthGuard gatewayAuthGuard;
    private final AuthProperties properties;
    private final com.intertec.autoops.auth.service.AuditService auditService;

    public AuthController(AuthFacade authFacade, UserService userService,
                          WorkspaceService workspaceService, IpResolver ipResolver,
                          GatewayAuthGuard gatewayAuthGuard, AuthProperties properties,
                          com.intertec.autoops.auth.service.AuditService auditService) {
        this.authFacade = authFacade;
        this.userService = userService;
        this.workspaceService = workspaceService;
        this.ipResolver = ipResolver;
        this.gatewayAuthGuard = gatewayAuthGuard;
        this.properties = properties;
        this.auditService = auditService;
    }

    // ---------------------------------------------------------------
    // Password register / login
    // ---------------------------------------------------------------

    @PostMapping("/register")
    public ResponseEntity<Map<String, String>> register(@Valid @RequestBody RegisterRequest request,
                                                        HttpServletRequest httpRequest) {
        // Deliberately does NOT pass the X-Tenant-ID tenant: sign-up always
        // creates a fresh workspace tenant (see AuthFacade.register). No tokens
        // until the emailed code proves ownership of the address.
        String email = authFacade.register(request.email(), request.password(),
                request.fullName(), request.workspaceName(),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
        return ResponseEntity.status(HttpStatus.ACCEPTED).body(Map.of(
                "status", "verification_required",
                "email", email,
                "message", "We emailed you a verification code."));
    }

    @PostMapping("/register/verify")
    public TokenResponse verifyRegistration(@Valid @RequestBody OtpVerifyRequest request,
                                            HttpServletRequest httpRequest) {
        return authFacade.verifyRegistration(request.email(), request.otp(),
                TenantContext.get(), request.deviceId(),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
    }

    @PostMapping("/register/resend")
    public ResponseEntity<Map<String, String>> resendRegistration(
            @Valid @RequestBody OtpGenerateRequest request, HttpServletRequest httpRequest) {
        authFacade.resendRegistrationOtp(request.email(), TenantContext.get(),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
        return ResponseEntity.ok(Map.of("status", "sent",
                "message", "If the account exists, a new code has been emailed."));
    }

    @PostMapping("/login")
    public TokenResponse login(@Valid @RequestBody LoginRequest request,
                               HttpServletRequest httpRequest) {
        return authFacade.passwordLogin(request.email(), request.password(),
                TenantContext.get(), request.deviceId(),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
    }

    // ---------------------------------------------------------------
    // OTP login
    // ---------------------------------------------------------------

    @PostMapping("/otp/generate")
    public ResponseEntity<Map<String, String>> generateOtp(@Valid @RequestBody OtpGenerateRequest request,
                                                           HttpServletRequest httpRequest) {
        // Throws user_not_found for unregistered emails when
        // autoops.auth.otp.reveal-unknown-account is on (the default); with it
        // off this is reached for every email and the message stays neutral.
        authFacade.initiateOtpLogin(request.email(), TenantContext.get(),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
        return ResponseEntity.ok(Map.of("status", "sent",
                "message", properties.getOtp().isRevealUnknownAccount()
                        ? "A one-time code has been emailed."
                        : "If the account exists, a one-time code has been emailed."));
    }

    @PostMapping("/otp/verify")
    public TokenResponse verifyOtp(@Valid @RequestBody OtpVerifyRequest request,
                                   HttpServletRequest httpRequest) {
        return authFacade.verifyOtpAndIssueTokens(request.email(), request.otp(),
                TenantContext.get(), request.deviceId(),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
    }

    // ---------------------------------------------------------------
    // Password reset / change
    // ---------------------------------------------------------------

    @PostMapping("/password/forgot")
    public ResponseEntity<Map<String, String>> forgotPassword(
            @Valid @RequestBody OtpGenerateRequest request, HttpServletRequest httpRequest) {
        authFacade.forgotPassword(request.email(), TenantContext.get(),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
        return ResponseEntity.ok(Map.of("status", "sent",
                "message", "If the account exists, a reset code has been emailed."));
    }

    @PostMapping("/password/reset")
    public TokenResponse resetPassword(@Valid @RequestBody ResetPasswordRequest request,
                                       HttpServletRequest httpRequest) {
        return authFacade.resetPassword(request.email(), request.otp(), request.newPassword(),
                TenantContext.get(), request.deviceId(),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
    }

    @PostMapping("/password/change")
    public TokenResponse changePassword(@Valid @RequestBody ChangePasswordRequest request,
                                        @AuthenticationPrincipal Jwt jwt,
                                        HttpServletRequest httpRequest) {
        return authFacade.changePassword(jwt, request.currentPassword(), request.newPassword(),
                request.deviceId(), ipResolver.resolve(httpRequest), userAgent(httpRequest));
    }

    // ---------------------------------------------------------------
    // Refresh / logout
    // ---------------------------------------------------------------

    @PostMapping("/refresh")
    public TokenResponse refresh(@Valid @RequestBody RefreshRequest request,
                                 HttpServletRequest httpRequest) {
        return authFacade.refresh(request.refreshToken(),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
    }

    @PostMapping("/logout")
    public ResponseEntity<Void> logout(@Valid @RequestBody RefreshRequest request,
                                       HttpServletRequest httpRequest) {
        authFacade.logout(request.refreshToken(),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
        return ResponseEntity.noContent().build();
    }

    @PostMapping("/logout-all")
    public Map<String, Object> logoutAll(@AuthenticationPrincipal Jwt jwt,
                                         HttpServletRequest httpRequest) {
        int revoked = authFacade.logoutAll(jwt,
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
        return Map.of("sessionsRevoked", revoked);
    }

    // ---------------------------------------------------------------
    // Authorize (token + entitlement) for internal services
    // ---------------------------------------------------------------

    @PostMapping("/authorize")
    public AuthorizeResponse authorize(@Valid @RequestBody AuthorizeRequest request,
                                       HttpServletRequest httpRequest) {
        // Internal endpoint: token validity and claims are only disclosed to
        // the gateway (HTTP Basic with the gateway client credentials).
        gatewayAuthGuard.requireGateway(httpRequest);
        return authFacade.authorize(request, TenantContext.get());
    }

    // ---------------------------------------------------------------
    // Keycloak SSO
    // ---------------------------------------------------------------

    @GetMapping("/sso/initiate")
    public ResponseEntity<Void> ssoInitiate() {
        return ResponseEntity.status(HttpStatus.FOUND)
                .location(URI.create(authFacade.ssoInitiate()))
                .build();
    }

    @GetMapping("/sso/callback")
    public ResponseEntity<?> ssoCallback(@RequestParam String code,
                                         @RequestParam String state,
                                         HttpServletRequest httpRequest) {
        TokenResponse tokens = authFacade.ssoCallback(code, state, TenantContext.get(),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
        return tokensToBrowser(tokens);
    }

    // ---------------------------------------------------------------
    // Social login: Google / Microsoft (direct OIDC, free on every plan)
    // ---------------------------------------------------------------

    @GetMapping("/sso/{provider:google|microsoft}")
    public ResponseEntity<Void> socialInitiate(@PathVariable String provider) {
        return ResponseEntity.status(HttpStatus.FOUND)
                .location(URI.create(authFacade.socialInitiate(provider)))
                .build();
    }

    @GetMapping("/sso/{provider:google|microsoft}/callback")
    public ResponseEntity<?> socialCallback(@PathVariable String provider,
                                            @RequestParam String code,
                                            @RequestParam String state,
                                            HttpServletRequest httpRequest) {
        try {
            TokenResponse tokens = authFacade.socialCallback(provider, code, state,
                    ipResolver.resolve(httpRequest), userAgent(httpRequest));
            return tokensToBrowser(tokens);
        } catch (AuthException ex) {
            // Browser flow: surface the error to the SPA callback page (in the
            // fragment, like the tokens) instead of a raw JSON body.
            return errorToBrowser(ex);
        }
    }

    private ResponseEntity<?> tokensToBrowser(TokenResponse tokens) {
        String redirect = properties.getKeycloak().getSuccessRedirect();
        if (redirect == null || redirect.isBlank()) {
            // API-client mode: no frontend configured, return the tokens.
            return ResponseEntity.ok(tokens);
        }
        // Browser mode: hand tokens to the SPA in the URL FRAGMENT — fragments
        // are never sent to servers, so they stay out of access logs.
        String fragment = "accessToken=" + url(tokens.accessToken())
                + "&refreshToken=" + url(tokens.refreshToken())
                + "&tokenType=Bearer&expiresIn=" + tokens.expiresIn();
        return ResponseEntity.status(HttpStatus.FOUND)
                .location(URI.create(redirect + "#" + fragment))
                .build();
    }

    /** Same contract as tokensToBrowser, but carrying an error instead. */
    private ResponseEntity<?> errorToBrowser(AuthException ex) {
        String redirect = properties.getKeycloak().getSuccessRedirect();
        if (redirect == null || redirect.isBlank()) {
            throw ex; // API-client mode: normal JSON error handling
        }
        String fragment = "error=" + url(ex.getError()) + "&message=" + url(ex.getMessage());
        return ResponseEntity.status(HttpStatus.FOUND)
                .location(URI.create(redirect + "#" + fragment))
                .build();
    }

    private static String url(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    // ---------------------------------------------------------------
    // Admin: onboard / offboard (ROLE_ADMIN enforced in SecurityConfig)
    // ---------------------------------------------------------------

    @PostMapping("/onboard")
    public ResponseEntity<UserProfileResponse> onboard(@Valid @RequestBody OnboardRequest request,
                                                       @AuthenticationPrincipal Jwt jwt,
                                                       HttpServletRequest httpRequest) {
        // Scope to the CALLER's tenant from their token, not the spoofable
        // X-Tenant-ID header or the request body.
        User user = authFacade.onboard(request, jwt.getClaimAsString("tenantId"),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
        return ResponseEntity.status(HttpStatus.CREATED).body(UserProfileResponse.from(user,
                workspaceService.displayName(user.getTenantId()).orElse(null)));
    }

    @PostMapping("/offboard/{userId}")
    public ResponseEntity<Void> offboard(@PathVariable Long userId,
                                         @AuthenticationPrincipal Jwt jwt,
                                         HttpServletRequest httpRequest) {
        authFacade.offboard(userId, callerId(jwt), jwt.getClaimAsString("tenantId"),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
        return ResponseEntity.noContent().build();
    }

    /** Team roster for the members page — always the caller's own tenant. */
    @GetMapping("/users")
    public java.util.List<UserProfileResponse> listUsers(@AuthenticationPrincipal Jwt jwt) {
        requireAdmin(jwt);
        return userService.listByTenant(jwt.getClaimAsString("tenantId")).stream()
                .map(user -> UserProfileResponse.from(user, null))
                .toList();
    }

    /**
     * Fixed platform role catalog + live member counts + the permission
     * matrix as actually enforced. Any member may view (unlike the roster,
     * which is admin-only).
     */
    @GetMapping("/roles")
    public com.intertec.autoops.auth.web.dto.RoleCatalogResponse roles(
            @AuthenticationPrincipal Jwt jwt) {
        return com.intertec.autoops.auth.web.dto.RoleCatalogResponse.forTenant(
                userService.listByTenant(jwt.getClaimAsString("tenantId")));
    }

    @PatchMapping("/users/{userId}/role")
    public UserProfileResponse changeRole(@PathVariable Long userId,
                                          @Valid @RequestBody RoleUpdateRequest request,
                                          @AuthenticationPrincipal Jwt jwt,
                                          HttpServletRequest httpRequest) {
        requireAdmin(jwt);
        User user = authFacade.changeRole(userId, request.role(), callerId(jwt),
                jwt.getClaimAsString("tenantId"),
                ipResolver.resolve(httpRequest), userAgent(httpRequest));
        return UserProfileResponse.from(user, null);
    }

    private static Long callerId(Jwt jwt) {
        Object claim = jwt.getClaim("userId");
        return claim instanceof Number number ? number.longValue() : null;
    }

    private void requireAdmin(Jwt jwt) {
        if (!"ADMIN".equals(jwt.getClaimAsString("role"))) {
            throw AuthException.forbidden("admin_required",
                    "Only workspace admins can manage members");
        }
    }

    // ---------------------------------------------------------------
    // Current user
    // ---------------------------------------------------------------

    @GetMapping("/me")
    public UserProfileResponse me(@AuthenticationPrincipal Jwt jwt) {
        Long userId = ((Number) jwt.getClaim("userId")).longValue();
        User user = userService.requireById(userId);
        return UserProfileResponse.from(user,
                workspaceService.displayName(user.getTenantId()).orElse(null));
    }

    /** Self-service profile edit — display name only; email is identity. */
    @PatchMapping("/me")
    public UserProfileResponse updateMe(@RequestBody Map<String, String> body,
                                        @AuthenticationPrincipal Jwt jwt,
                                        HttpServletRequest httpRequest) {
        Long userId = ((Number) jwt.getClaim("userId")).longValue();
        User user = userService.updateFullName(userId, body.get("fullName"));
        auditService.record(com.intertec.autoops.auth.domain.AuditEventType.PROFILE_UPDATED,
                userId, user.getEmail(),
                user.getTenantId(), null, ipResolver.resolve(httpRequest),
                userAgent(httpRequest), null);
        return UserProfileResponse.from(user,
                workspaceService.displayName(user.getTenantId()).orElse(null));
    }

    /**
     * Admin rename of the caller's OWN workspace — tenant from the token
     * claim, so one workspace can never rename another.
     */
    @PatchMapping("/workspace")
    public Map<String, String> renameWorkspace(@Valid @RequestBody WorkspaceUpdateRequest request,
                                               @AuthenticationPrincipal Jwt jwt,
                                               HttpServletRequest httpRequest) {
        if (!"ADMIN".equals(jwt.getClaimAsString("role"))) {
            throw AuthException.forbidden("admin_required",
                    "Only workspace admins can rename the workspace");
        }
        Long userId = ((Number) jwt.getClaim("userId")).longValue();
        String name = workspaceService.rename(jwt.getClaimAsString("tenantId"), request.name(),
                userId, jwt.getSubject(), ipResolver.resolve(httpRequest), userAgent(httpRequest));
        return Map.of("workspaceName", name);
    }

    private String userAgent(HttpServletRequest request) {
        return request.getHeader(HttpHeaders.USER_AGENT);
    }
}
