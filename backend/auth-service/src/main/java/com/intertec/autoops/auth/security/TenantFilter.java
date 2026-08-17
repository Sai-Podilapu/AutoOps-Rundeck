package com.intertec.autoops.auth.security;

import com.intertec.autoops.auth.config.AuthProperties;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * Resolves the tenant for the request.
 *
 * <p>The X-Tenant-ID header is client-supplied, so it is only meaningful when
 * a trusted gateway sets/overwrites it. Deployments behind such a gateway
 * should set {@code autoops.auth.tenant.require-header=true} (the prod
 * default), which rejects requests without the header instead of silently
 * falling back to the default tenant. Single-tenant/dev deployments may leave
 * it false and use the configured default tenant.
 */
@Component
public class TenantFilter extends OncePerRequestFilter {

    private final AuthProperties properties;

    public TenantFilter(AuthProperties properties) {
        this.properties = properties;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain) throws ServletException, IOException {
        String header = request.getHeader(TenantContext.HEADER);
        String tenantId = header != null && !header.isBlank() ? header.trim() : null;

        if (tenantId == null) {
            if (properties.getTenant().isRequireHeader()) {
                response.setStatus(HttpServletResponse.SC_BAD_REQUEST);
                response.setContentType(MediaType.APPLICATION_JSON_VALUE);
                response.getWriter().write(
                        "{\"error\":\"tenant_required\",\"message\":\"X-Tenant-ID header is required\"}");
                return;
            }
            tenantId = properties.getTenant().getDefaultTenant();
        }

        try {
            TenantContext.set(tenantId);
            filterChain.doFilter(request, response);
        } finally {
            TenantContext.clear();
        }
    }
}
