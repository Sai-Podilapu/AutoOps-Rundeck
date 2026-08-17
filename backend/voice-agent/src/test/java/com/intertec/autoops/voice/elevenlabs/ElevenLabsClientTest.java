package com.intertec.autoops.voice.elevenlabs;

import com.intertec.autoops.voice.config.VoiceProperties;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.header;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

class ElevenLabsClientTest {

    private static VoiceProperties configured() {
        VoiceProperties properties = new VoiceProperties();
        properties.setApiKey("sk_test_key");
        properties.setAgentId("agent_abc123");
        properties.setApiBaseUrl("https://api.elevenlabs.io");
        return properties;
    }

    private record Fixture(ElevenLabsClient client, MockRestServiceServer server) {
    }

    private static Fixture fixture(VoiceProperties properties) {
        RestClient.Builder builder = RestClient.builder();
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        return new Fixture(new ElevenLabsClient(properties, builder), server);
    }

    @Test
    void sendsTheKeyAsAHeaderAndReturnsTheSignedUrl() {
        Fixture f = fixture(configured());
        f.server().expect(requestTo(
                        "https://api.elevenlabs.io/v1/convai/conversation/get-signed-url?agent_id=agent_abc123"))
                .andExpect(method(org.springframework.http.HttpMethod.GET))
                .andExpect(header("xi-api-key", "sk_test_key"))
                .andRespond(withSuccess("{\"signed_url\":\"wss://api.elevenlabs.io/v1/convai/conversation?token=xyz\"}",
                        MediaType.APPLICATION_JSON));

        assertThat(f.client().signedUrl())
                .isEqualTo("wss://api.elevenlabs.io/v1/convai/conversation?token=xyz");
        f.server().verify();
    }

    @Test
    void refusesToCallOutWhenNoCredentialsAreConfigured() {
        Fixture f = fixture(new VoiceProperties());

        assertThatThrownBy(() -> f.client().signedUrl())
                .isInstanceOf(ElevenLabsException.class)
                .hasMessageContaining("not configured");
        // Nothing was sent — an unconfigured deployment must not hit the network.
        f.server().verify();
    }

    @Test
    void aRejectedApiKeyIsNotLeakedToTheVisitor() {
        Fixture f = fixture(configured());
        f.server().expect(requestTo(org.hamcrest.Matchers.containsString("get-signed-url")))
                .andRespond(withStatus(HttpStatus.UNAUTHORIZED)
                        .body("{\"detail\":\"invalid api key sk_test_key\"}")
                        .contentType(MediaType.APPLICATION_JSON));

        assertThatThrownBy(() -> f.client().signedUrl())
                .isInstanceOf(ElevenLabsException.class)
                .satisfies(e -> assertThat(((ElevenLabsException) e).getStatus())
                        .isEqualTo(HttpStatus.SERVICE_UNAVAILABLE))
                .hasMessage("The voice agent is not available right now");
    }

    @Test
    void anUnknownAgentIdReadsAsUnavailableRatherThanNotFound() {
        Fixture f = fixture(configured());
        f.server().expect(requestTo(org.hamcrest.Matchers.containsString("get-signed-url")))
                .andRespond(withStatus(HttpStatus.NOT_FOUND));

        assertThatThrownBy(() -> f.client().signedUrl())
                .isInstanceOf(ElevenLabsException.class)
                .satisfies(e -> assertThat(((ElevenLabsException) e).getStatus())
                        .isEqualTo(HttpStatus.SERVICE_UNAVAILABLE));
    }

    @Test
    void upstreamThrottlingIsPassedThroughAs429() {
        Fixture f = fixture(configured());
        f.server().expect(requestTo(org.hamcrest.Matchers.containsString("get-signed-url")))
                .andRespond(withStatus(HttpStatus.TOO_MANY_REQUESTS));

        assertThatThrownBy(() -> f.client().signedUrl())
                .isInstanceOf(ElevenLabsException.class)
                .satisfies(e -> assertThat(((ElevenLabsException) e).getStatus())
                        .isEqualTo(HttpStatus.TOO_MANY_REQUESTS));
    }

    @Test
    void anUpstreamOutageBecomesABadGateway() {
        Fixture f = fixture(configured());
        f.server().expect(requestTo(org.hamcrest.Matchers.containsString("get-signed-url")))
                .andRespond(withStatus(HttpStatus.INTERNAL_SERVER_ERROR));

        assertThatThrownBy(() -> f.client().signedUrl())
                .isInstanceOf(ElevenLabsException.class)
                .satisfies(e -> assertThat(((ElevenLabsException) e).getStatus())
                        .isEqualTo(HttpStatus.BAD_GATEWAY));
    }

    @Test
    void aSuccessWithNoUrlIsTreatedAsAFailureNotAnEmptySession() {
        Fixture f = fixture(configured());
        f.server().expect(requestTo(org.hamcrest.Matchers.containsString("get-signed-url")))
                .andRespond(withSuccess("{}", MediaType.APPLICATION_JSON));

        assertThatThrownBy(() -> f.client().signedUrl())
                .isInstanceOf(ElevenLabsException.class)
                .satisfies(e -> assertThat(((ElevenLabsException) e).getStatus())
                        .isEqualTo(HttpStatus.BAD_GATEWAY));
    }
}
