package com.intertec.autoops.auth.web.dto;

/**
 * RFC 7662 introspection response shape (documentation aid). The live
 * endpoint is served by Spring Authorization Server at /oauth2/introspect
 * (gateway client, HTTP Basic).
 */
public record IntrospectResponse(
        boolean active,
        String sub,
        Long userId,
        String role,
        String tenantId,
        Long exp) {
}
