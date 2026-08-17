package com.intertec.autoops.gateway.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletRequestWrapper;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.Collections;
import java.util.Enumeration;
import java.util.List;

/**
 * The "trusted gateway" the platform's tenant model relies on: when the caller
 * presents a valid access token, X-Tenant-ID is OVERWRITTEN with the token's
 * own {@code tenantId} claim before the request is proxied downstream — a
 * client can never smuggle another workspace's tenant header past the edge.
 * Anonymous requests (login, register) pass their header through untouched;
 * auth-service treats it as untrusted input for those flows by design.
 *
 * <p>Runs after the security filter chain (Boot registers component filters
 * later), so the SecurityContext is already populated.
 */
@Component
public class TenantHeaderFilter extends OncePerRequestFilter {

    public static final String TENANT_HEADER = "X-Tenant-ID";

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain) throws ServletException, IOException {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        if (authentication instanceof JwtAuthenticationToken jwtAuth) {
            String tenantId = jwtAuth.getToken().getClaimAsString("tenantId");
            if (tenantId != null && !tenantId.isBlank()) {
                filterChain.doFilter(new TenantOverridingRequest(request, tenantId), response);
                return;
            }
        }
        filterChain.doFilter(request, response);
    }

    private static final class TenantOverridingRequest extends HttpServletRequestWrapper {

        private final String tenantId;

        TenantOverridingRequest(HttpServletRequest request, String tenantId) {
            super(request);
            this.tenantId = tenantId;
        }

        @Override
        public String getHeader(String name) {
            if (TENANT_HEADER.equalsIgnoreCase(name)) {
                return tenantId;
            }
            return super.getHeader(name);
        }

        @Override
        public Enumeration<String> getHeaders(String name) {
            if (TENANT_HEADER.equalsIgnoreCase(name)) {
                return Collections.enumeration(List.of(tenantId));
            }
            return super.getHeaders(name);
        }

        @Override
        public Enumeration<String> getHeaderNames() {
            java.util.LinkedHashSet<String> names = new java.util.LinkedHashSet<>();
            Enumeration<String> original = super.getHeaderNames();
            while (original.hasMoreElements()) {
                names.add(original.nextElement());
            }
            names.add(TENANT_HEADER);
            return Collections.enumeration(names);
        }
    }
}
