package com.intertec.autoops.rundeck.security;

import com.intertec.autoops.rundeck.config.RundeckProperties;
import jakarta.servlet.FilterChain;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

/**
 * The guard on {@code /internal/**}.
 *
 * <p>This is the strongest check in the service and worth asserting directly: a
 * caller who got past it could dispatch a job on any tenant's fleet AND choose
 * whose, because the tenant is a request parameter on that path rather than a
 * token claim.
 */
class InternalTokenFilterTest {

    private InternalTokenFilter filter;
    private FilterChain chain;

    @BeforeEach
    void setUp() {
        RundeckProperties properties = new RundeckProperties();
        properties.setInternalToken("real-internal-token");
        filter = new InternalTokenFilter(properties);
        chain = mock(FilterChain.class);
    }

    private MockHttpServletResponse call(String uri, String token) throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("POST", uri);
        request.setRequestURI(uri);
        if (token != null) {
            request.addHeader(InternalTokenFilter.HEADER, token);
        }
        MockHttpServletResponse response = new MockHttpServletResponse();
        // doFilter honours shouldNotFilter, which is the behaviour under test
        // for the non-/internal paths below.
        filter.doFilter(request, response, chain);
        return response;
    }

    @Test
    @DisplayName("the correct token reaches the controller")
    void correctTokenPasses() throws Exception {
        MockHttpServletResponse response =
                call("/internal/rundeck/dispatch", "real-internal-token");

        assertThat(response.getStatus()).isEqualTo(200);
        verify(chain).doFilter(any(), any());
    }

    @Test
    @DisplayName("a missing token is 401 and never reaches a controller")
    void missingTokenRejected() throws Exception {
        MockHttpServletResponse response = call("/internal/rundeck/dispatch", null);

        assertThat(response.getStatus()).isEqualTo(401);
        assertThat(response.getContentAsString()).contains("invalid_internal_token");
        verify(chain, never()).doFilter(any(), any());
    }

    @Test
    @DisplayName("a wrong token is 401")
    void wrongTokenRejected() throws Exception {
        MockHttpServletResponse response =
                call("/internal/rundeck/dispatch", "not-the-token");

        assertThat(response.getStatus()).isEqualTo(401);
        verify(chain, never()).doFilter(any(), any());
    }

    @Test
    @DisplayName("a PREFIX of the real token is 401 — length is part of the comparison")
    void truncatedTokenRejected() throws Exception {
        MockHttpServletResponse response = call("/internal/rundeck/dispatch", "real-internal");

        assertThat(response.getStatus()).isEqualTo(401);
        verify(chain, never()).doFilter(any(), any());
    }

    @Test
    @DisplayName("an empty token is 401")
    void emptyTokenRejected() throws Exception {
        MockHttpServletResponse response = call("/internal/rundeck/dispatch", "");

        assertThat(response.getStatus()).isEqualTo(401);
        verify(chain, never()).doFilter(any(), any());
    }

    @Test
    @DisplayName("/api paths are not guarded here — the bearer chain owns those")
    void apiPathsAreNotFiltered() throws Exception {
        MockHttpServletResponse response = call("/api/rundeck/connections", null);

        assertThat(response.getStatus()).isEqualTo(200);
        verify(chain).doFilter(any(), any());
    }

    @Test
    @DisplayName("/actuator stays outside the guard so health checks keep working")
    void actuatorIsNotFiltered() throws Exception {
        MockHttpServletResponse response = call("/actuator/health", null);

        assertThat(response.getStatus()).isEqualTo(200);
        verify(chain).doFilter(any(), any());
    }
}
