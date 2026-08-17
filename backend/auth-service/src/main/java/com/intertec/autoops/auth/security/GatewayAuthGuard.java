package com.intertec.autoops.auth.security;

import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.exception.AuthException;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpHeaders;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;

/**
 * HTTP Basic authentication against the gateway client credentials for
 * internal endpoints (/api/auth/authorize). Mirrors the client auth already
 * required by /oauth2/introspect: token validity and claims are never
 * disclosed to anonymous callers.
 */
@Component
public class GatewayAuthGuard {

    private final AuthProperties properties;

    public GatewayAuthGuard(AuthProperties properties) {
        this.properties = properties;
    }

    public void requireGateway(HttpServletRequest request) {
        String header = request.getHeader(HttpHeaders.AUTHORIZATION);
        if (header == null || !header.startsWith("Basic ")) {
            throw AuthException.unauthorized("invalid_client", "Gateway credentials required");
        }
        String decoded;
        try {
            decoded = new String(Base64.getDecoder().decode(header.substring(6)),
                    StandardCharsets.UTF_8);
        } catch (IllegalArgumentException ex) {
            throw AuthException.unauthorized("invalid_client", "Gateway credentials required");
        }
        int separator = decoded.indexOf(':');
        if (separator < 0) {
            throw AuthException.unauthorized("invalid_client", "Gateway credentials required");
        }
        String clientId = decoded.substring(0, separator);
        String clientSecret = decoded.substring(separator + 1);

        boolean idMatches = constantTimeEquals(clientId,
                properties.getGatewayClient().getClientId());
        boolean secretMatches = constantTimeEquals(clientSecret,
                properties.getGatewayClient().getClientSecret());
        if (!(idMatches && secretMatches)) {
            throw AuthException.unauthorized("invalid_client", "Gateway credentials required");
        }
    }

    private boolean constantTimeEquals(String a, String b) {
        return MessageDigest.isEqual(
                a.getBytes(StandardCharsets.UTF_8),
                b.getBytes(StandardCharsets.UTF_8));
    }
}
