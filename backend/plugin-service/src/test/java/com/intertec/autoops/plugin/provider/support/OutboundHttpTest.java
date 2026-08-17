package com.intertec.autoops.plugin.provider.support;

import com.intertec.autoops.plugin.spi.DeliveryResult;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.time.Duration;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Covers the one thing the shared HTTP path can silently get wrong: what
 * actually goes on the wire.
 *
 * <p>A real loopback server is used rather than a mock because the bug this
 * guards against — Spring re-encoding an already-encoded URL — happens inside
 * the client, below anything a mocked RestClient would show.
 */
class OutboundHttpTest {

    private HttpServer server;
    private final AtomicReference<String> receivedQuery = new AtomicReference<>();

    @BeforeEach
    void startServer() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/invoke", exchange -> {
            receivedQuery.set(exchange.getRequestURI().getRawQuery());
            exchange.sendResponseHeaders(202, -1);
            exchange.close();
        });
        server.start();
    }

    @AfterEach
    void stopServer() {
        server.stop(0);
    }

    private String url(String query) {
        return "http://127.0.0.1:" + server.getAddress().getPort() + "/invoke?" + query;
    }

    private OutboundHttp http() {
        return new OutboundHttp(Duration.ofSeconds(2), Duration.ofSeconds(2));
    }

    /**
     * The Teams 401: a Logic Apps SAS signature is already percent-encoded, and
     * treating the URL as a URI template doubles every {@code %} to {@code %25},
     * which invalidates the signature.
     */
    @Test
    void sendsAnAlreadyEncodedQueryStringByteForByte() {
        String query = "api-version=2016-06-01&sp=%2Ftriggers%2Fmanual%2Frun&sig=Ab%2BcD%2FefGh%3D";

        DeliveryResult result = http().postJson(url(query), Map.of("type", "message"));

        assertThat(result.ok()).isTrue();
        assertThat(receivedQuery.get()).isEqualTo(query);
        assertThat(receivedQuery.get()).doesNotContain("%25");
    }

    /** Pasted secrets pick up trailing whitespace; that must not become %20. */
    @Test
    void trimsSurroundingWhitespaceRatherThanEncodingIt() {
        String query = "sig=abc";

        DeliveryResult result = http().postJson("  " + url(query) + "  ", Map.of());

        assertThat(result.ok()).isTrue();
        assertThat(receivedQuery.get()).isEqualTo(query);
    }

    /** A malformed URL is the tenant's typo — permanent, never retried. */
    @Test
    void reportsAnUnparseableUrlAsPermanent() {
        DeliveryResult result = http().postJson("https://example.com/a b", Map.of());

        assertThat(result.ok()).isFalse();
        assertThat(result.retryable()).isFalse();
        assertThat(result.detail()).contains("Not a usable URL");
    }

    /** A brace in a webhook URL must not be read as a template placeholder. */
    @Test
    void doesNotTreatBracesAsPlaceholders() {
        String query = "token=%7Babc%7D";

        DeliveryResult result = http().postJson(url(query), Map.of());

        assertThat(result.ok()).isTrue();
        assertThat(receivedQuery.get()).isEqualTo(query);
    }

    /** Registers an endpoint that answers with the given status and body. */
    private String endpoint(String path, int status, String body) {
        server.createContext(path, exchange -> {
            byte[] bytes = body.getBytes();
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(status, bytes.length);
            exchange.getResponseBody().write(bytes);
            exchange.close();
        });
        return "http://127.0.0.1:" + server.getAddress().getPort() + path;
    }

    /** 4xx must arrive as a recorded result, not an exception, and not retry. */
    @Test
    void mapsAClientErrorToAPermanentFailure() {
        DeliveryResult result = http()
                .postJson(endpoint("/denied", 401, "{\"error\":\"nope\"}"), Map.of());

        assertThat(result.ok()).isFalse();
        assertThat(result.retryable()).isFalse();
        assertThat(result.statusCode()).isEqualTo(401);
    }

    /**
     * The provider's own explanation must reach the delivery log. 403 rather
     * than 401 deliberately: HttpURLConnection eats the error stream on a 401
     * when there is no WWW-Authenticate header, so that one status can only
     * ever be logged as a bare code.
     */
    @Test
    void carriesTheProvidersErrorTextIntoTheDetail() {
        DeliveryResult result = http()
                .postJson(endpoint("/forbidden", 403, "{\"error\":\"flow is off\"}"), Map.of());

        assertThat(result.ok()).isFalse();
        assertThat(result.detail()).contains("flow is off");
    }

    /** A 429 is the provider asking us to back off, not a broken config. */
    @Test
    void mapsRateLimitingToRetryable() {
        DeliveryResult result = http()
                .postJson(endpoint("/throttled", 429, "{\"error\":\"slow down\"}"), Map.of());

        assertThat(result.retryable()).isTrue();
        assertThat(result.statusCode()).isEqualTo(429);
    }
}