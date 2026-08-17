package com.intertec.autoops.jobs.security;

import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.StepRunner;
import com.intertec.autoops.jobs.execution.test.TestRunner;
import com.intertec.autoops.jobs.sandbox.StepSandbox;
import com.intertec.autoops.jobs.service.StepExecutionService;
import com.intertec.autoops.jobs.web.ExecuteController;
import com.intertec.autoops.jobs.web.VerifyController;
import com.intertec.autoops.jobs.verify.CredentialVerificationService;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * The only door in front of a service that runs arbitrary commands by design.
 * Covers the token check itself, the paths it guards (and the ones it must
 * leave alone), and that a rejected call never reaches a controller.
 */
class InternalTokenFilterTest {

    private static final String TOKEN = "s3cret-platform-token";

    private final JobProperties properties = properties(TOKEN);
    private final InternalTokenFilter filter = new InternalTokenFilter(properties);

    // ---- the token check ----

    @Test
    void rejectsAMissingToken() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        MockFilterChain chain = new MockFilterChain();

        filter.doFilter(request("/internal/execute", null), response, chain);

        assertEquals(401, response.getStatus());
        assertEquals("application/json", response.getContentType());
        assertTrue(response.getContentAsString().contains("invalid_internal_token"));
        assertNull(chain.getRequest(), "the request must not reach the application");
    }

    @Test
    void rejectsAWrongToken() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        MockFilterChain chain = new MockFilterChain();

        filter.doFilter(request("/internal/execute", "not-the-token"), response, chain);

        assertEquals(401, response.getStatus());
        assertNull(chain.getRequest());
    }

    /** MessageDigest.isEqual is length-safe: a valid prefix is still wrong. */
    @Test
    void rejectsAPrefixOfTheToken() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        MockFilterChain chain = new MockFilterChain();

        filter.doFilter(request("/internal/execute", TOKEN.substring(0, TOKEN.length() - 1)),
                response, chain);

        assertEquals(401, response.getStatus());
        assertNull(chain.getRequest());
    }

    @Test
    void rejectsAnEmptyToken() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        MockFilterChain chain = new MockFilterChain();

        filter.doFilter(request("/internal/execute", ""), response, chain);

        assertEquals(401, response.getStatus());
        assertNull(chain.getRequest());
    }

    @Test
    void letsTheRightTokenThrough() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        MockFilterChain chain = new MockFilterChain();

        filter.doFilter(request("/internal/execute", TOKEN), response, chain);

        assertEquals(200, response.getStatus());
        assertNotNull(chain.getRequest(), "the request must reach the application");
    }

    // ---- which paths are guarded ----

    @Test
    void guardsEveryInternalEndpoint() {
        assertFalse(filter.shouldNotFilter(request("/internal/execute", null)));
        assertFalse(filter.shouldNotFilter(request("/internal/verify", null)));
        assertFalse(filter.shouldNotFilter(request("/internal/anything/new", null)));
    }

    /** Health and metrics are how compose and Prometheus see this container. */
    @Test
    void leavesActuatorAlone() {
        assertTrue(filter.shouldNotFilter(request("/actuator/health", null)));
        assertTrue(filter.shouldNotFilter(request("/actuator/prometheus", null)));
        assertTrue(filter.shouldNotFilter(request("/", null)));
    }

    /** "/internalish" must not be mistaken for the guarded prefix. */
    @Test
    void doesNotMatchALookalikePrefix() {
        assertTrue(filter.shouldNotFilter(request("/internalish", null)));
    }

    // ---- through the real controllers ----

    @Test
    void executeIsUnreachableWithoutTheToken() throws Exception {
        mockMvc().perform(post("/internal/execute")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"tenantId\":\"t1\",\"stepType\":\"test\",\"value\":\"hi\"}"))
                .andExpect(status().isUnauthorized())
                .andExpect(content().string(org.hamcrest.Matchers.containsString(
                        "invalid_internal_token")));
    }

    @Test
    void verifyIsUnreachableWithoutTheToken() throws Exception {
        mockMvc().perform(post("/internal/verify")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"tenantId\":\"t1\",\"platform\":\"AWS\",\"data\":{}}"))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void executeRunsTheStepWithTheToken() throws Exception {
        mockMvc().perform(post("/internal/execute")
                        .header(InternalTokenFilter.HEADER, TOKEN)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"tenantId\":\"t1\",\"stepType\":\"test\",\"value\":\"hi\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.success").value(true))
                .andExpect(jsonPath("$.output").value("hi"));
    }

    // ------------------------------------------------------------------

    private MockMvc mockMvc() {
        StepSandbox sandbox = new StepSandbox(properties);
        StepExecutionService stepExecutionService = new StepExecutionService(
                List.of((StepRunner) new TestRunner()), properties, sandbox, emptyProvider());
        CredentialVerificationService verificationService =
                new CredentialVerificationService(new ObjectMapper(), sandbox, emptyProvider());
        return MockMvcBuilders
                .standaloneSetup(new ExecuteController(stepExecutionService),
                        new VerifyController(verificationService))
                .addFilters(filter)
                .build();
    }

    private static MockHttpServletRequest request(String uri, String token) {
        MockHttpServletRequest request = new MockHttpServletRequest("POST", uri);
        request.setRequestURI(uri);
        if (token != null) {
            request.addHeader(InternalTokenFilter.HEADER, token);
        }
        return request;
    }

    private static JobProperties properties(String token) {
        JobProperties properties = new JobProperties();
        properties.setInternalToken(token);
        // See StepExecutionServiceTest: the suite must run in a root container.
        properties.getSandbox().setAllowRootSteps(true);
        return properties;
    }

    private static <T> ObjectProvider<T> emptyProvider() {
        return new ObjectProvider<>() {
            @Override
            public T getIfAvailable() {
                return null;
            }

            @Override
            public T getObject() {
                throw new UnsupportedOperationException();
            }
        };
    }
}