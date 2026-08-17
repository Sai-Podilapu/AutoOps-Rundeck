package com.intertec.autoops.auth.security;

import com.intertec.autoops.auth.domain.User;
import com.intertec.autoops.auth.domain.UserStatus;
import com.intertec.autoops.auth.repo.UserRepository;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtException;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.List;

/**
 * Validates AutoOps RS256 access tokens on /api/** routes.
 *
 * <p>Beyond the signature/expiry checks done by the {@link JwtDecoder}, this
 * filter enforces:
 * <ul>
 *   <li>{@code iss} matches the configured issuer</li>
 *   <li>{@code tokenType == "access"}</li>
 *   <li>{@code ver} equals the user's current {@code token_version} — so
 *       logout-all / offboard instantly invalidates outstanding tokens</li>
 *   <li>the user still exists and is ACTIVE</li>
 * </ul>
 * Invalid tokens simply leave the request unauthenticated; protected routes
 * then get a JSON 401 from {@link RestAuthEntryPoint}.
 */
@Component
public class JwtAuthFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(JwtAuthFilter.class);
    private static final String BEARER_PREFIX = "Bearer ";

    private final JwtDecoder jwtDecoder;
    private final UserRepository userRepository;
    private final String issuer;

    public JwtAuthFilter(JwtDecoder jwtDecoder,
                         UserRepository userRepository,
                         com.intertec.autoops.auth.config.AuthProperties properties) {
        this.jwtDecoder = jwtDecoder;
        this.userRepository = userRepository;
        this.issuer = properties.getIssuer();
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain) throws ServletException, IOException {
        String header = request.getHeader(HttpHeaders.AUTHORIZATION);
        if (header == null || !header.startsWith(BEARER_PREFIX)) {
            filterChain.doFilter(request, response);
            return;
        }
        String token = header.substring(BEARER_PREFIX.length());
        try {
            Jwt jwt = jwtDecoder.decode(token);
            if (isValidAutoOpsAccessToken(jwt)) {
                String role = jwt.getClaimAsString("role");
                JwtAuthenticationToken authentication = new JwtAuthenticationToken(
                        jwt,
                        List.of(new SimpleGrantedAuthority("ROLE_" + role)),
                        jwt.getSubject());
                SecurityContextHolder.getContext().setAuthentication(authentication);
            }
        } catch (JwtException ex) {
            log.debug("Rejected bearer token: {}", ex.getMessage());
            SecurityContextHolder.clearContext();
        }
        filterChain.doFilter(request, response);
    }

    private boolean isValidAutoOpsAccessToken(Jwt jwt) {
        if (!issuer.equals(jwt.getClaimAsString("iss"))) {
            return false;
        }
        if (!"access".equals(jwt.getClaimAsString("tokenType"))) {
            return false;
        }
        Long userId = jwt.getClaim("userId") != null
                ? ((Number) jwt.getClaim("userId")).longValue()
                : null;
        Number ver = jwt.getClaim("ver");
        if (userId == null || ver == null) {
            return false;
        }
        User user = userRepository.findById(userId).orElse(null);
        if (user == null || user.getStatus() != UserStatus.ACTIVE) {
            return false;
        }
        // Token version check: logout-all / offboard bumps users.token_version.
        return user.getTokenVersion() == ver.intValue();
    }
}
