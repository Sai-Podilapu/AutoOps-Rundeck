package com.intertec.autoops.gateway.security;

import jakarta.servlet.http.HttpServletRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;

import java.util.Collections;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The spoof-proofing the platform's tenant model relies on: an authenticated
 * request's X-Tenant-ID must always be the token's own claim, whatever the
 * client sent.
 */
class TenantHeaderFilterTest {

    private final TenantHeaderFilter filter = new TenantHeaderFilter();

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void overwritesSpoofedHeaderWithTokenClaim() throws Exception {
        authenticateWithTenant("tenant-real");
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.addHeader(TenantHeaderFilter.TENANT_HEADER, "tenant-victim");

        HttpServletRequest downstream = doFilter(request);

        assertEquals("tenant-real", downstream.getHeader(TenantHeaderFilter.TENANT_HEADER));
        assertEquals(List.of("tenant-real"),
                Collections.list(downstream.getHeaders(TenantHeaderFilter.TENANT_HEADER)));
    }

    @Test
    void addsHeaderWhenClientSentNone() throws Exception {
        authenticateWithTenant("tenant-a");

        HttpServletRequest downstream = doFilter(new MockHttpServletRequest());

        assertEquals("tenant-a", downstream.getHeader(TenantHeaderFilter.TENANT_HEADER));
        assertTrue(Collections.list(downstream.getHeaderNames())
                .contains(TenantHeaderFilter.TENANT_HEADER));
    }

    @Test
    void headerLookupIsCaseInsensitive() throws Exception {
        authenticateWithTenant("tenant-a");

        HttpServletRequest downstream = doFilter(new MockHttpServletRequest());

        assertEquals("tenant-a", downstream.getHeader("x-tenant-id"));
    }

    @Test
    void anonymousRequestPassesHeaderThroughUntouched() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.addHeader(TenantHeaderFilter.TENANT_HEADER, "tenant-from-client");

        HttpServletRequest downstream = doFilter(request);

        // Login/register: auth-service treats the header as untrusted input.
        assertEquals("tenant-from-client", downstream.getHeader(TenantHeaderFilter.TENANT_HEADER));
    }

    @Test
    void blankTenantClaimLeavesRequestUntouched() throws Exception {
        authenticateWithTenant(" ");

        HttpServletRequest downstream = doFilter(new MockHttpServletRequest());

        assertNull(downstream.getHeader(TenantHeaderFilter.TENANT_HEADER));
    }

    // ------------------------------------------------------------------

    private void authenticateWithTenant(String tenantId) {
        Jwt jwt = Jwt.withTokenValue("token")
                .header("alg", "RS256")
                .subject("user@example.com")
                .claim("tenantId", tenantId)
                .claim("tokenType", "access")
                .build();
        SecurityContextHolder.getContext().setAuthentication(new JwtAuthenticationToken(jwt));
    }

    private HttpServletRequest doFilter(MockHttpServletRequest request) throws Exception {
        MockFilterChain chain = new MockFilterChain();
        filter.doFilter(request, new MockHttpServletResponse(), chain);
        return (HttpServletRequest) chain.getRequest();
    }
}
