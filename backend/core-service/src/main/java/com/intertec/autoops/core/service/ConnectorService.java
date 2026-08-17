package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.domain.Connector;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.ConnectorRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Locale;

/**
 * Third-party plugins. Config is encrypted at rest; "test" performs a REAL
 * call against the target — a Slack webhook post, a generic webhook ping, or
 * a GitHub API read — and records the outcome on the row. No fake green
 * lights: a connector that has never been tested shows exactly that.
 */
@Service
public class ConnectorService {

    private static final Logger log = LoggerFactory.getLogger(ConnectorService.class);
    private static final Duration TIMEOUT = Duration.ofSeconds(10);

    private final ConnectorRepository connectorRepository;
    private final SubscriptionGate gate;
    private final CredentialCrypto crypto;
    private final ObjectMapper objectMapper;

    public ConnectorService(ConnectorRepository connectorRepository, SubscriptionGate gate,
                            CredentialCrypto crypto, ObjectMapper objectMapper) {
        this.connectorRepository = connectorRepository;
        this.gate = gate;
        this.crypto = crypto;
        this.objectMapper = objectMapper;
    }

    @Transactional(readOnly = true)
    public List<Connector> list(String tenantId) {
        return connectorRepository.findByTenantIdOrderByCreatedAtDesc(tenantId);
    }

    @Transactional
    public Connector create(String tenantId, String actor, String accessToken,
                            String kindCode, String name, String configJson) {
        gate.requireActive(accessToken);
        Connector.Kind kind = parseKind(kindCode);
        validateConfig(kind, configJson);
        Connector connector = new Connector();
        connector.setTenantId(tenantId);
        connector.setKind(kind);
        connector.setName(name);
        connector.setConfigEnc(crypto.encrypt(configJson));
        connector.setCreatedBy(actor);
        Connector saved = connectorRepository.save(connector);
        log.info("Tenant {} added {} connector {}", tenantId, kind, saved.getId());
        return saved;
    }

    @Transactional
    public void delete(String tenantId, String accessToken, Long id) {
        gate.requireActive(accessToken);
        connectorRepository.delete(require(tenantId, id));
    }

    public record TestResult(boolean ok, String message) {
    }

    /** A REAL call against the connected service; outcome stored on the row. */
    @Transactional
    public TestResult test(String tenantId, String accessToken, Long id) {
        gate.requireActive(accessToken);
        Connector connector = require(tenantId, id);
        TestResult result;
        try {
            JsonNode config = objectMapper.readTree(crypto.decrypt(connector.getConfigEnc()));
            result = switch (connector.getKind()) {
                case SLACK_WEBHOOK -> post(config.path("url").asText(),
                        "{\"text\":\"AutoOps connection test — this connector works.\"}",
                        "Slack accepted the test message");
                case GENERIC_WEBHOOK -> post(config.path("url").asText(),
                        "{\"event\":\"autoops.connector.test\"}",
                        "Endpoint accepted the test event");
                case GITHUB -> github(config.path("repo").asText(),
                        config.path("token").asText());
            };
        } catch (Exception ex) {
            result = new TestResult(false, "Test call failed: " + ex.getMessage());
        }
        connector.setLastTestOk(result.ok());
        connector.setLastTestAt(Instant.now());
        connectorRepository.save(connector);
        log.info("Tenant {} tested connector {} -> {}", tenantId, id, result.ok());
        return result;
    }

    private TestResult post(String url, String body, String okMessage) throws Exception {
        if (url == null || !url.startsWith("https://")) {
            return new TestResult(false, "Connector has no https:// URL configured");
        }
        HttpResponse<String> response = send(HttpRequest.newBuilder(URI.create(url))
                .timeout(TIMEOUT)
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build());
        return response.statusCode() < 400
                ? new TestResult(true, okMessage)
                : new TestResult(false, "Endpoint answered HTTP " + response.statusCode());
    }

    private TestResult github(String repo, String token) throws Exception {
        if (repo == null || repo.isBlank() || !repo.matches("[\\w.-]+/[\\w.-]+")) {
            return new TestResult(false, "Configure the repo as owner/name");
        }
        HttpRequest.Builder request = HttpRequest
                .newBuilder(URI.create("https://api.github.com/repos/" + repo))
                .timeout(TIMEOUT)
                .header("Accept", "application/vnd.github+json");
        if (token != null && !token.isBlank()) {
            request.header("Authorization", "Bearer " + token);
        }
        HttpResponse<String> response = send(request.build());
        return response.statusCode() == 200
                ? new TestResult(true, "GitHub repo " + repo + " is reachable")
                : new TestResult(false, "GitHub answered HTTP " + response.statusCode()
                        + (response.statusCode() == 404 ? " — repo not found or token lacks access" : ""));
    }

    private HttpResponse<String> send(HttpRequest request) throws Exception {
        try (HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build()) {
            return client.send(request, HttpResponse.BodyHandlers.ofString());
        }
    }

    private void validateConfig(Connector.Kind kind, String configJson) {
        JsonNode config;
        try {
            config = objectMapper.readTree(configJson);
        } catch (Exception ex) {
            throw CoreException.badRequest("invalid_config", "Connector config is not valid JSON");
        }
        boolean ok = switch (kind) {
            case SLACK_WEBHOOK, GENERIC_WEBHOOK ->
                    config.path("url").asText("").startsWith("https://");
            case GITHUB -> config.path("repo").asText("").matches("[\\w.-]+/[\\w.-]+");
        };
        if (!ok) {
            throw CoreException.badRequest("invalid_config", switch (kind) {
                case SLACK_WEBHOOK -> "Slack connectors need {\"url\": \"https://hooks.slack.com/...\"}";
                case GENERIC_WEBHOOK -> "Webhook connectors need {\"url\": \"https://...\"}";
                case GITHUB -> "GitHub connectors need {\"repo\": \"owner/name\", \"token\": \"...\"}";
            });
        }
    }

    private Connector require(String tenantId, Long id) {
        return connectorRepository.findByIdAndTenantId(id, tenantId)
                .orElseThrow(() -> CoreException.notFound("connector_not_found",
                        "No such connector"));
    }

    private static Connector.Kind parseKind(String code) {
        try {
            return Connector.Kind.valueOf(code.trim().toUpperCase(Locale.ROOT)
                    .replace("-", "_"));
        } catch (Exception ex) {
            throw CoreException.badRequest("unknown_connector_kind",
                    "Connector kind must be slack_webhook, generic_webhook, or github");
        }
    }
}
