package com.intertec.autoops.gateway.config;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.test.web.servlet.MockMvc;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.options;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Edge rules only — no downstream services are running, so tests stick to
 * requests the security layer answers by itself (401s, public actuator
 * endpoints, CORS preflights). Routing itself is configuration owned by
 * spring-cloud-gateway-mvc.
 */
@SpringBootTest
@AutoConfigureMockMvc
class SecurityConfigTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void protectedRouteWithoutTokenIs401WithJsonErrorShape() throws Exception {
        mockMvc.perform(post("/api/subscriptions/subscribe"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error").value("unauthorized"))
                .andExpect(jsonPath("$.message").value("A valid access token is required"));
    }

    @Test
    void garbageBearerTokenIs401() throws Exception {
        mockMvc.perform(get("/api/entitlements/check")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer not-a-jwt"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error").value("unauthorized"));
    }

    @Test
    void healthIsPublic() throws Exception {
        mockMvc.perform(get("/actuator/health"))
                .andExpect(status().isOk());
    }

    @Test
    void prometheusIsNotPublic() throws Exception {
        mockMvc.perform(get("/actuator/prometheus"))
                .andExpect(status().isUnauthorized());
    }

    /**
     * Landing-page visitors have no token, so the two Aegis-01 endpoints must
     * clear the edge. voice-agent is not running here, so a request that got
     * through security fails trying to connect to it — reaching the proxy at
     * all is the proof that it was never challenged for a token.
     */
    @Test
    void voiceConfigIsAnonymous() {
        assertReachedTheProxy(() -> mockMvc.perform(get("/api/voice/config")), "8085");
    }

    @Test
    void voiceSessionIsAnonymous() {
        assertReachedTheProxy(() -> mockMvc.perform(post("/api/voice/session")), "8085");
    }

    private void assertReachedTheProxy(ThrowingRequest request, String downstreamPort) {
        Exception thrown = assertThrows(Exception.class, request::perform);
        Throwable root = thrown;
        while (root.getCause() != null) {
            root = root.getCause();
        }
        assertTrue(thrown.getMessage() != null && thrown.getMessage().contains(downstreamPort),
                "expected the request to be forwarded downstream, but failed with: " + root);
    }

    @FunctionalInterface
    private interface ThrowingRequest {
        void perform() throws Exception;
    }

    @Test
    void otherVoicePathsStillRequireAToken() throws Exception {
        // The permit list is two exact endpoints, not the /api/voice/** prefix:
        // anything voice-agent grows later is authenticated until chosen otherwise.
        mockMvc.perform(get("/api/voice/conversations"))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void voiceSessionRejectsMethodsOtherThanPost() throws Exception {
        mockMvc.perform(get("/api/voice/session"))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void corsPreflightAllowsConfiguredDevOrigin() throws Exception {
        mockMvc.perform(options("/api/plans")
                        .header(HttpHeaders.ORIGIN, "http://localhost:5173")
                        .header(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET"))
                .andExpect(status().isOk())
                .andExpect(header().string("Access-Control-Allow-Origin", "http://localhost:5173"));
    }

    @Test
    void corsPreflightRejectsUnknownOrigin() throws Exception {
        mockMvc.perform(options("/api/plans")
                        .header(HttpHeaders.ORIGIN, "https://evil.example")
                        .header(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET"))
                .andExpect(status().isForbidden());
    }

    // ------ accessTokenOnly claim rule (no JWKS needed) ------

    @Test
    void accessTokensPassTheTokenTypeRule() {
        OAuth2TokenValidatorResult result =
                SecurityConfig.accessTokenOnly().validate(jwtWithTokenType("access"));
        assertFalse(result.hasErrors());
    }

    @Test
    void refreshTokensFailTheTokenTypeRule() {
        OAuth2TokenValidatorResult result =
                SecurityConfig.accessTokenOnly().validate(jwtWithTokenType("refresh"));
        assertTrue(result.hasErrors());
    }

    @Test
    void tokensWithoutTokenTypeFailTheRule() {
        Jwt jwt = Jwt.withTokenValue("token")
                .header("alg", "RS256")
                .subject("user@example.com")
                .build();
        assertTrue(SecurityConfig.accessTokenOnly().validate(jwt).hasErrors());
    }

    private Jwt jwtWithTokenType(String tokenType) {
        return Jwt.withTokenValue("token")
                .header("alg", "RS256")
                .subject("user@example.com")
                .claim("tokenType", tokenType)
                .build();
    }
}
