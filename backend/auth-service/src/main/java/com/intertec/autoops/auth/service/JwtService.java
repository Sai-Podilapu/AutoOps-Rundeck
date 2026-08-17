package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.config.JwkConfig;
import com.intertec.autoops.auth.domain.User;
import com.intertec.autoops.auth.exception.AuthException;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.JwsHeader;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.security.oauth2.jwt.JwtException;
import org.springframework.stereotype.Service;

import java.time.Instant;

/**
 * RS256 access token mint/validate against the local JWKS.
 *
 * <p>Claims: sub=email, userId, role, tenantId, tokenType="access", status,
 * ver (users.token_version), iss, iat, exp (15m default). The `ver` claim is
 * additionally re-checked against the DB in JwtAuthFilter / AuthFacade.
 */
@Service
public class JwtService {

    private final JwtEncoder jwtEncoder;
    private final JwtDecoder jwtDecoder; // @Primary decoder over the local JWKS
    private final AuthProperties properties;
    private final JwkConfig.SigningKey signingKey;

    public JwtService(JwtEncoder jwtEncoder, JwtDecoder jwtDecoder, AuthProperties properties,
                      JwkConfig.SigningKey signingKey) {
        this.jwtEncoder = jwtEncoder;
        this.jwtDecoder = jwtDecoder;
        this.properties = properties;
        this.signingKey = signingKey;
    }

    public String mintAccessToken(User user) {
        Instant now = Instant.now();
        JwtClaimsSet claims = JwtClaimsSet.builder()
                .issuer(properties.getIssuer())
                .issuedAt(now)
                .expiresAt(now.plus(properties.getAccessTokenTtl()))
                .subject(user.getEmail())
                .claim("userId", user.getId())
                .claim("role", user.getRole().name())
                .claim("tenantId", user.getTenantId())
                .claim("tokenType", "access")
                .claim("status", user.getStatus().name())
                .claim("ver", user.getTokenVersion())
                .build();
        // Explicit kid: the JWKS may hold several keys during rotation.
        JwsHeader header = JwsHeader.with(SignatureAlgorithm.RS256)
                .keyId(signingKey.kid())
                .build();
        return jwtEncoder.encode(JwtEncoderParameters.from(header, claims)).getTokenValue();
    }

    /** Signature + expiry via the decoder, then issuer and tokenType checks. */
    public Jwt validateAccessToken(String token) {
        Jwt jwt;
        try {
            jwt = jwtDecoder.decode(token);
        } catch (JwtException ex) {
            throw AuthException.unauthorized("invalid_token", "Token is invalid or expired");
        }
        if (!properties.getIssuer().equals(jwt.getClaimAsString("iss"))) {
            throw AuthException.unauthorized("invalid_token", "Unexpected token issuer");
        }
        if (!"access".equals(jwt.getClaimAsString("tokenType"))) {
            throw AuthException.unauthorized("invalid_token", "Not an access token");
        }
        return jwt;
    }

    public long accessTokenTtlSeconds() {
        return properties.getAccessTokenTtl().toSeconds();
    }
}
