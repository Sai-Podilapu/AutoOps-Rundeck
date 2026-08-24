package com.intertec.autoops.rundeck.client;

import com.intertec.autoops.rundeck.config.RundeckProperties;
import com.intertec.autoops.rundeck.exception.RundeckException;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

import java.io.IOException;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * The Rundeck adapter against a loopback HTTP stub.
 *
 * <p>A stub rather than a mock because the things most likely to be wrong here
 * are wire-level: the verb on abort, the {@code ?format=json} on the job export,
 * the auth header name, and how a Rundeck error body becomes an AutoOps error
 * code. None of those are visible to a mocked RestClient.
 */
class RundeckApiClientTest {

    private HttpServer server;
    private RundeckApiClient client;
    private RundeckApiClient.Target target;

    /** Every request the stub saw: "METHOD /path?query". */
    private final List<String> requests = new ArrayList<>();
    private final List<String> authHeaders = new ArrayList<>();
    private final List<String> bodies = new ArrayList<>();
    /** path -> [status, body] */
    private final Map<String, Object[]> responses = new ConcurrentHashMap<>();

    @BeforeEach
    void startStub() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", this::handle);
        server.start();

        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(2000);
        factory.setReadTimeout(4000);
        RundeckProperties properties = new RundeckProperties();
        client = new RundeckApiClient(
                RestClient.builder().requestFactory(factory).build(), properties);
        target = new RundeckApiClient.Target(
                "http://127.0.0.1:" + server.getAddress().getPort(), 41, "secret-token");
    }

    @AfterEach
    void stopStub() {
        server.stop(0);
    }

    private void handle(HttpExchange exchange) throws IOException {
        // getPath() DECODES; getRawPath() is what actually came over the wire.
        // The distinction is the whole point of the encoding test below.
        String path = exchange.getRequestURI().getPath();
        String rawPath = exchange.getRequestURI().getRawPath();
        String query = exchange.getRequestURI().getQuery();
        requests.add(exchange.getRequestMethod() + " " + rawPath
                + (query == null ? "" : "?" + query));
        authHeaders.add(String.valueOf(exchange.getRequestHeaders()
                .getFirst("X-Rundeck-Auth-Token")));
        try (InputStream in = exchange.getRequestBody()) {
            bodies.add(new String(in.readAllBytes(), StandardCharsets.UTF_8));
        }
        Object[] configured = responses.getOrDefault(path, new Object[]{200, "{}"});
        byte[] payload = String.valueOf(configured[1]).getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", "application/json");
        exchange.sendResponseHeaders((int) configured[0], payload.length);
        exchange.getResponseBody().write(payload);
        exchange.close();
    }

    private void stub(String path, int status, String body) {
        responses.put(path, new Object[]{status, body});
    }

    @Test
    @DisplayName("systemInfo reads the nested system.rundeck block and sends the auth token")
    void systemInfoParsesAndAuthenticates() {
        stub("/api/41/system/info", 200, """
                {"system":{"rundeck":{"version":"5.6.0","serverName":"rd-prod-1",
                "apiversion":41}}}""");

        RundeckApiClient.SystemInfo info = client.systemInfo(target);

        assertThat(info.version()).isEqualTo("5.6.0");
        assertThat(info.serverName()).isEqualTo("rd-prod-1");
        assertThat(requests).containsExactly("GET /api/41/system/info");
        // The header name is the whole authentication scheme — a typo here
        // would look like "Rundeck rejected the token" forever.
        assertThat(authHeaders).containsExactly("secret-token");
    }

    @Test
    @DisplayName("the API version in the path comes from the connection, not a constant")
    void apiVersionIsPerConnection() {
        stub("/api/18/projects", 200, "[]");

        client.listProjects(new RundeckApiClient.Target(
                "http://127.0.0.1:" + server.getAddress().getPort(), 18, "t"));

        assertThat(requests).containsExactly("GET /api/18/projects");
    }

    @Test
    @DisplayName("a project name with a space is percent-encoded on the wire")
    void projectNamesAreEncoded() {
        // Stubbed by the DECODED path, because that is what the server resolves
        // a context against once it has undone the encoding.
        stub("/api/41/project/My Ops/jobs", 200, "[]");

        client.listJobs(target, "My Ops");

        // Asserted on the RAW path: a space sent literally would either 404 or
        // address a different resource, and Rundeck project names contain them.
        assertThat(requests).containsExactly("GET /api/41/project/My%20Ops/jobs");
    }

    @Test
    @DisplayName("the job export asks for JSON — /info would carry no options")
    void jobDefinitionUsesTheExportEndpoint() {
        stub("/api/41/job/abc-123", 200, """
                [{"id":"abc-123","name":"Restart API","project":"Ops",
                  "options":[{"name":"env","required":true}]}]""");

        Map<String, Object> definition = client.jobDefinition(target, "abc-123");

        assertThat(definition).containsEntry("name", "Restart API");
        assertThat(requests).containsExactly("GET /api/41/job/abc-123?format=json");
    }

    @Test
    @DisplayName("an empty export is a 404, not an index-out-of-bounds")
    void emptyJobExportIsNotFound() {
        stub("/api/41/job/ghost", 200, "[]");

        assertThatThrownBy(() -> client.jobDefinition(target, "ghost"))
                .isInstanceOf(RundeckException.class)
                .hasMessageContaining("ghost");
    }

    @Test
    @DisplayName("runJob posts options and the node filter in the body")
    void runJobSendsOptionsAndFilter() {
        stub("/api/41/job/abc-123/run", 200, """
                {"id":4711,"status":"running","project":"Ops","job":{"id":"abc-123",
                 "name":"Restart API"}}""");

        Map<String, Object> body = client.runJob(target, "abc-123",
                Map.of("env", "prod"), "tags: web+prod", "INFO", null);

        assertThat(body).containsEntry("id", 4711);
        assertThat(requests).containsExactly("POST /api/41/job/abc-123/run");
        // The body must actually be sent — a dropped RestClient spec would
        // silently run the job with every option at its default.
        assertThat(bodies.get(0)).contains("\"env\":\"prod\"")
                .contains("\"filter\":\"tags: web+prod\"")
                .contains("\"loglevel\":\"INFO\"")
                // asUser was null, so it must be absent rather than null —
                // a server without runAs permission would refuse the request.
                .doesNotContain("asUser");
    }

    @Test
    @DisplayName("abort is a GET — the verb every Rundeck version accepts")
    void abortUsesGet() {
        stub("/api/41/execution/4711/abort", 200,
                "{\"abort\":{\"status\":\"pending\"},\"execution\":{\"id\":4711}}");

        client.abort(target, 4711);

        assertThat(requests).containsExactly("GET /api/41/execution/4711/abort");
    }

    @Test
    @DisplayName("log output passes the offset cursor through untouched")
    void logOutputTails() {
        stub("/api/41/execution/4711/output", 200, """
                {"execCompleted":false,"offset":"2048","entries":[{"log":"hello"}]}""");

        client.executionOutput(target, 4711, "1024", 50);

        assertThat(requests).containsExactly(
                "GET /api/41/execution/4711/output?maxlines=50&offset=1024");
    }

    @Test
    @DisplayName("maxLines is capped by configuration, not by the caller")
    void logLinesAreCapped() {
        stub("/api/41/execution/4711/output", 200, "{}");

        client.executionOutput(target, 4711, null, 100_000);

        // 500 is the configured default ceiling; a caller asking for 100k must
        // not be able to make this service buffer an entire execution log.
        assertThat(requests).containsExactly(
                "GET /api/41/execution/4711/output?maxlines=500");
    }

    @Test
    @DisplayName("401 becomes rundeck_unauthorized and names the token, not the network")
    void unauthorizedIsTranslated() {
        stub("/api/41/projects", 401,
                "{\"error\":true,\"message\":\"Unauthorized: token revoked\"}");

        assertThatThrownBy(() -> client.listProjects(target))
                .isInstanceOf(RundeckException.class)
                .hasMessageContaining("rejected the stored API token")
                .hasMessageContaining("token revoked")
                .satisfies(ex -> assertThat(((RundeckException) ex).getError())
                        .isEqualTo("rundeck_unauthorized"));
    }

    @Test
    @DisplayName("404 becomes rundeck_not_found carrying Rundeck's own message")
    void notFoundIsTranslated() {
        stub("/api/41/project/Ops/jobs", 404,
                "{\"error\":true,\"message\":\"Project does not exist: Ops\"}");

        assertThatThrownBy(() -> client.listJobs(target, "Ops"))
                .isInstanceOf(RundeckException.class)
                .hasMessage("Project does not exist: Ops")
                .satisfies(ex -> assertThat(((RundeckException) ex).getError())
                        .isEqualTo("rundeck_not_found"));
    }

    @Test
    @DisplayName("a 500 becomes a 502 — this service is fine, the upstream is not")
    void upstreamErrorIsBadGateway() {
        stub("/api/41/projects", 500, "{\"error\":true,\"message\":\"boom\"}");

        assertThatThrownBy(() -> client.listProjects(target))
                .isInstanceOf(RundeckException.class)
                .satisfies(ex -> {
                    assertThat(((RundeckException) ex).getError()).isEqualTo("rundeck_error");
                    assertThat(((RundeckException) ex).getStatus().value()).isEqualTo(502);
                });
    }

    @Test
    @DisplayName("an HTML login page (wrong base URL) is reported, not swallowed")
    void htmlResponseIsSurfaced() {
        stub("/api/41/projects", 403,
                "<html><body>Please log in to Rundeck</body></html>");

        assertThatThrownBy(() -> client.listProjects(target))
                .isInstanceOf(RundeckException.class)
                .hasMessageContaining("Please log in");
    }

    @Test
    @DisplayName("an unreachable host is rundeck_unreachable, never a 500")
    void unreachableHostIsTranslated() {
        // Port 1 on loopback: nothing listens, connection refused immediately.
        RundeckApiClient.Target dead =
                new RundeckApiClient.Target("http://127.0.0.1:1", 41, "t");

        assertThatThrownBy(() -> client.listProjects(dead))
                .isInstanceOf(RundeckException.class)
                .satisfies(ex -> assertThat(((RundeckException) ex).getError())
                        .isEqualTo("rundeck_unreachable"));
    }

    @Test
    @DisplayName("a trailing slash on the base URL does not double up in the path")
    void baseUrlTrailingSlashIsNormalized() {
        stub("/api/41/projects", 200, "[]");

        client.listProjects(new RundeckApiClient.Target(
                "http://127.0.0.1:" + server.getAddress().getPort() + "/", 41, "t"));

        assertThat(requests).containsExactly("GET /api/41/projects");
    }
}
