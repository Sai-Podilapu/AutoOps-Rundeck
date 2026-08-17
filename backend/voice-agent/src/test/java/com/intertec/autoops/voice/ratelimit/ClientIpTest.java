package com.intertec.autoops.voice.ratelimit;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;

import static org.assertj.core.api.Assertions.assertThat;

class ClientIpTest {

    @Test
    void prefersTheOriginalClientFromXForwardedFor() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setRemoteAddr("172.18.0.5");
        request.addHeader("X-Forwarded-For", "203.0.113.7, 10.0.0.2");

        assertThat(ClientIp.of(request)).isEqualTo("203.0.113.7");
    }

    @Test
    void fallsBackToTheSocketAddressWithoutTheHeader() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setRemoteAddr("198.51.100.4");

        assertThat(ClientIp.of(request)).isEqualTo("198.51.100.4");
    }

    @Test
    void aBlankHeaderDoesNotShadowTheSocketAddress() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setRemoteAddr("198.51.100.4");
        request.addHeader("X-Forwarded-For", "   ");

        assertThat(ClientIp.of(request)).isEqualTo("198.51.100.4");
    }

    @Test
    void anEmptyLeadingEntryFallsBackRatherThanBucketingEveryoneTogether() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setRemoteAddr("198.51.100.4");
        request.addHeader("X-Forwarded-For", " , 10.0.0.2");

        assertThat(ClientIp.of(request)).isEqualTo("198.51.100.4");
    }

    @Test
    void anUnknownAddressIsLabelledRatherThanNull() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setRemoteAddr(null);

        assertThat(ClientIp.of(request)).isEqualTo("unknown");
    }
}
