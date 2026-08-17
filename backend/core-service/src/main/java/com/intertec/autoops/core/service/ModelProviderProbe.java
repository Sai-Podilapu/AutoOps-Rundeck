package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.domain.ModelProvider.Kind;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Proves a stored model-provider credential by making a REAL, read-only call
 * against the vendor — never by inspecting the key's shape.
 *
 * <p>Every vendor here exposes a "list models" endpoint that requires exactly
 * the credential we are testing, so one request does both jobs: it fails when
 * the key is wrong, and returns the tenant's actual model list when it is
 * right. That is why the catalog's model lists are fallbacks only — the
 * authoritative list is whatever the vendor just said.
 *
 * <p>The credential is decrypted, used, and dropped inside a single call. It
 * is never logged, and never travels back to a client.
 */
@Component
public class ModelProviderProbe {

    private static final Logger log = LoggerFactory.getLogger(ModelProviderProbe.class);
    private static final Duration TIMEOUT = Duration.ofSeconds(15);
    private static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(6);
    /** Enough to pick a model; keeps a chatty vendor out of the response. */
    private static final int MAX_MODELS = 200;
    /** Vendor key prefixes, so a quoted error can never carry part of one. */
    private static final java.util.regex.Pattern SECRET_LIKE = java.util.regex.Pattern
            .compile("(?i)\\b(sk|xai|gsk|AIza|AKIA|ASIA)[-_A-Za-z0-9]{6,}");

    private final ObjectMapper objectMapper;

    public ModelProviderProbe(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    /**
     * @param ok      whether the vendor accepted the credential
     * @param message operator-facing reason, safe to display
     * @param models  model ids the vendor reported; empty when the call failed
     */
    public record ProbeResult(boolean ok, String message, List<String> models) {

        static ProbeResult failed(String message) {
            return new ProbeResult(false, message, List.of());
        }
    }

    public ProbeResult probe(Kind kind, JsonNode config) {
        return probe(kind, config, null);
    }

    /**
     * @param defaultModel the model this workspace picked, used only where a
     *                     credential can be proven by inference but not by
     *                     listing (see {@link #openai}). Null is fine.
     */
    public ProbeResult probe(Kind kind, JsonNode config, String defaultModel) {
        try {
            return switch (kind) {
                case OPENAI -> openai(config.path("apiKey").asText(""), defaultModel);
                case ANTHROPIC -> anthropic(config.path("apiKey").asText(""));
                case GOOGLE -> google(config.path("apiKey").asText(""));
                case AZURE_OPENAI -> azure(config);
                case BEDROCK -> bedrock(config);
                case HUAWEI -> huawei(config);
                case MISTRAL -> bearer(kind, "https://api.mistral.ai/v1/models",
                        config.path("apiKey").asText(""));
                case GROQ -> bearer(kind, "https://api.groq.com/openai/v1/models",
                        config.path("apiKey").asText(""));
                case DEEPSEEK -> bearer(kind, "https://api.deepseek.com/models",
                        config.path("apiKey").asText(""));
                case XAI -> bearer(kind, "https://api.x.ai/v1/models",
                        config.path("apiKey").asText(""));
                case OPENROUTER -> openRouter(config.path("apiKey").asText(""));
                case HUGGINGFACE -> huggingFace(config.path("apiKey").asText(""));
                case ELEVENLABS -> elevenLabs(config.path("apiKey").asText(""));
                case SAGEMAKER -> sageMaker(config);
                case OLLAMA -> ollama(config);
            };
        } catch (Exception ex) {
            // Network-level failure (DNS, TLS, timeout) — the message is the
            // useful part; the credential must never reach the log.
            log.info("Model provider probe for {} failed: {}", kind, ex.toString());
            return ProbeResult.failed("Could not reach the provider: " + rootMessage(ex));
        }
    }

    // ---- per-vendor calls ----------------------------------------------

    /** The OpenAI-schema vendors: Bearer token, {"data":[{"id":...}]}. */
    private ProbeResult bearer(Kind kind, String url, String apiKey) throws Exception {
        return interpret(bearerGet(url, apiKey), node -> ids(node.path("data"), "id"),
                describe(kind));
    }

    private HttpResponse<String> bearerGet(String url, String apiKey) throws Exception {
        return send(HttpRequest.newBuilder(URI.create(url))
                .timeout(TIMEOUT)
                .header("Authorization", "Bearer " + apiKey)
                .GET()
                .build());
    }

    /**
     * OpenRouter and Hugging Face both publish their model list WITHOUT
     * authentication, so probing that list would hand a green tick to any
     * string at all. The credential is proven against an endpoint that
     * genuinely requires it, and only then is the list fetched.
     *
     * @param authUrl requires the token — this is what proves the credential
     * @param listUrl public; read only after the token has been proven
     */
    private ProbeResult provenThenListed(String vendor, String authUrl, String listUrl,
                                         String apiKey, ModelReader reader) throws Exception {
        HttpResponse<String> auth = bearerGet(authUrl, apiKey);
        if (auth.statusCode() >= 400) {
            return interpret(auth, node -> List.of(), vendor);
        }
        HttpResponse<String> listed = bearerGet(listUrl, apiKey);
        if (listed.statusCode() >= 400) {
            // The key is good; only the catalogue call failed. Saying the
            // credential was rejected would send someone hunting the wrong bug.
            return new ProbeResult(true,
                    vendor + " accepted the credential (model list unavailable)", List.of());
        }
        return interpret(listed, reader, vendor);
    }

    private ProbeResult openRouter(String apiKey) throws Exception {
        return provenThenListed("OpenRouter",
                "https://openrouter.ai/api/v1/key",
                "https://openrouter.ai/api/v1/models",
                apiKey, node -> ids(node.path("data"), "id"));
    }

    private ProbeResult huggingFace(String apiKey) throws Exception {
        // The Hub holds over a million repos, so "every model" is not a useful
        // answer. This asks for the ones served by an inference provider —
        // the models a token can actually call — newest first.
        return provenThenListed("Hugging Face",
                "https://huggingface.co/api/whoami-v2",
                "https://huggingface.co/api/models?inference_provider=all"
                        + "&sort=trendingScore&direction=-1&limit=100",
                apiKey, node -> ids(node, "id"));
    }

    /** ElevenLabs authenticates on xi-api-key and answers with a bare array. */
    private ProbeResult elevenLabs(String apiKey) throws Exception {
        HttpResponse<String> response = send(
                HttpRequest.newBuilder(URI.create("https://api.elevenlabs.io/v1/models"))
                        .timeout(TIMEOUT)
                        .header("xi-api-key", apiKey)
                        .GET()
                        .build());
        return interpret(response, node -> ids(node, "model_id"), "ElevenLabs");
    }

    /**
     * SageMaker has no published model catalogue: what a tenant can call is
     * the ENDPOINTS they deployed, which is also what goes in the model field.
     * Listing them is a JSON-RPC POST rather than a GET, hence the payload
     * signature.
     *
     * <p>An account with no endpoints yet is a success with an empty list —
     * the credential is proven, there is simply nothing deployed.
     */
    private ProbeResult sageMaker(JsonNode config) throws Exception {
        String region = config.path("region").asText("");
        String host = "api.sagemaker." + region + ".amazonaws.com";
        String payload = "{\"MaxResults\":100}";
        var signed = SigV4Signer.signAws("POST", host, "/", "sagemaker", region,
                config.path("accessKeyId").asText(""),
                config.path("secretAccessKey").asText(""),
                payload, Instant.now());

        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create("https://" + host + "/"))
                .timeout(TIMEOUT)
                .header("Content-Type", "application/x-amz-json-1.1")
                .header("X-Amz-Target", "SageMaker.ListEndpoints")
                .POST(HttpRequest.BodyPublishers.ofString(payload));
        signed.headers().forEach(request::header);

        return interpret(send(request.build()),
                node -> ids(node.path("Endpoints"), "EndpointName"), "Amazon SageMaker");
    }

    /**
     * OpenAI, which needs two attempts because one key can be legitimate and
     * still fail the obvious check.
     *
     * <p>Listing models requires the {@code api.model.read} scope. A
     * RESTRICTED key minted only for inference does not carry it — that key
     * runs every call an agent will ever make, and still answers 401 here.
     * Reporting it as a bad credential would be wrong, so when OpenAI says
     * the SCOPE is what is missing (rather than the key being incorrect), the
     * key is proven the way an agent would use it: one minimal, capped
     * completion. That path returns no model list, so the console keeps
     * offering the catalog's suggestions and says they are unverified.
     */
    private ProbeResult openai(String apiKey, String defaultModel) throws Exception {
        ProbeResult listed = bearer(Kind.OPENAI, "https://api.openai.com/v1/models", apiKey);
        if (listed.ok() || !deniedForScope(listed.message())) {
            return listed;
        }
        String model = defaultModel == null || defaultModel.isBlank()
                ? "gpt-4o-mini"
                : defaultModel.trim();
        log.info("OpenAI key lacks api.model.read; proving it with a {} completion", model);
        return openaiInference(apiKey, model);
    }

    /** A denial about PERMISSIONS, not about the key being wrong. */
    private static boolean deniedForScope(String message) {
        if (message == null) {
            return false;
        }
        String lower = message.toLowerCase(java.util.Locale.ROOT);
        return lower.contains("insufficient permission")
                || lower.contains("missing scopes")
                || lower.contains("api.model.read");
    }

    private ProbeResult openaiInference(String apiKey, String model) throws Exception {
        String body = objectMapper.writeValueAsString(Map.of(
                "model", model,
                "input", "ping",
                "max_output_tokens", 16));
        HttpResponse<String> response = send(
                HttpRequest.newBuilder(URI.create("https://api.openai.com/v1/responses"))
                        .timeout(TIMEOUT)
                        .header("Authorization", "Bearer " + apiKey)
                        .header("Content-Type", "application/json")
                        .POST(HttpRequest.BodyPublishers.ofString(body))
                        .build());
        if (response.statusCode() >= 400) {
            String detail = vendorMessage(response.body());
            return ProbeResult.failed("OpenAI rejected the credential (HTTP "
                    + response.statusCode() + ")"
                    + (detail == null ? "" : " — " + detail));
        }
        return new ProbeResult(true, "OpenAI accepted the credential — this key is scoped "
                + "for inference only (verified with " + model + "), so its model list "
                + "cannot be read", List.of());
    }

    private ProbeResult anthropic(String apiKey) throws Exception {
        HttpResponse<String> response = send(
                HttpRequest.newBuilder(URI.create("https://api.anthropic.com/v1/models"))
                        .timeout(TIMEOUT)
                        // Anthropic authenticates on x-api-key, not Authorization,
                        // and rejects the request outright without a version header.
                        .header("x-api-key", apiKey)
                        .header("anthropic-version", "2023-06-01")
                        .GET()
                        .build());
        return interpret(response, node -> ids(node.path("data"), "id"), "Anthropic");
    }

    private ProbeResult google(String apiKey) throws Exception {
        String url = "https://generativelanguage.googleapis.com/v1beta/models?key="
                + URLEncoder.encode(apiKey, StandardCharsets.UTF_8);
        HttpResponse<String> response = send(HttpRequest.newBuilder(URI.create(url))
                .timeout(TIMEOUT)
                .GET()
                .build());
        // Google returns "models/gemini-2.5-pro"; callers want the bare id.
        return interpret(response,
                node -> ids(node.path("models"), "name").stream()
                        .map(id -> id.startsWith("models/") ? id.substring(7) : id)
                        .toList(),
                "Google Gemini");
    }

    private ProbeResult azure(JsonNode config) throws Exception {
        String endpoint = trimSlash(config.path("endpoint").asText(""));
        String apiVersion = config.path("apiVersion").asText("");
        if (apiVersion.isBlank()) {
            apiVersion = "2024-10-21";
        }
        String url = endpoint + "/openai/models?api-version="
                + URLEncoder.encode(apiVersion, StandardCharsets.UTF_8);
        HttpResponse<String> response = send(HttpRequest.newBuilder(URI.create(url))
                .timeout(TIMEOUT)
                .header("api-key", config.path("apiKey").asText(""))
                .GET()
                .build());
        return interpret(response, node -> ids(node.path("data"), "id"), "Azure OpenAI");
    }

    private ProbeResult bedrock(JsonNode config) throws Exception {
        String region = config.path("region").asText("");
        String host = "bedrock." + region + ".amazonaws.com";
        var signed = SigV4Signer.signAws(host, "/foundation-models", "bedrock", region,
                config.path("accessKeyId").asText(""),
                config.path("secretAccessKey").asText(""),
                Instant.now());

        HttpRequest.Builder request =
                HttpRequest.newBuilder(URI.create("https://" + host + "/foundation-models"))
                        .timeout(TIMEOUT)
                        .GET();
        signed.headers().forEach(request::header);

        return interpret(send(request.build()),
                node -> ids(node.path("modelSummaries"), "modelId"), "AWS Bedrock");
    }

    private ProbeResult huawei(JsonNode config) throws Exception {
        String region = config.path("region").asText("");
        String projectId = config.path("projectId").asText("");
        String host = "modelarts." + region + ".myhuaweicloud.com";
        String path = "/v1/" + projectId + "/models";
        var signed = SigV4Signer.signHuawei(host, path,
                config.path("accessKey").asText(""),
                config.path("secretKey").asText(""),
                Instant.now());

        HttpRequest.Builder request =
                HttpRequest.newBuilder(URI.create("https://" + host + path))
                        .timeout(TIMEOUT)
                        .GET();
        signed.headers().forEach(request::header);

        return interpret(send(request.build()),
                node -> ids(node.path("models"), "model_name"), "Huawei ModelArts");
    }

    private ProbeResult ollama(JsonNode config) throws Exception {
        String baseUrl = trimSlash(config.path("baseUrl").asText(""));
        HttpRequest.Builder request =
                HttpRequest.newBuilder(URI.create(baseUrl + "/api/tags"))
                        .timeout(TIMEOUT)
                        .GET();
        // Optional: a reverse proxy in front of Ollama may still want a token.
        String apiKey = config.path("apiKey").asText("");
        if (!apiKey.isBlank()) {
            request.header("Authorization", "Bearer " + apiKey);
        }
        return interpret(send(request.build()),
                node -> ids(node.path("models"), "name"), "Ollama");
    }

    // ---- shared plumbing ------------------------------------------------

    private interface ModelReader {
        List<String> read(JsonNode body);
    }

    private ProbeResult interpret(HttpResponse<String> response, ModelReader reader,
                                  String vendor) {
        int status = response.statusCode();
        // The vendor's own sentence is the useful part: "Incorrect API key"
        // and "Missing scopes: api.model.read" are different problems with
        // different fixes, and both used to surface as the same flat denial.
        String detail = vendorMessage(response.body());
        if (status == 401 || status == 403) {
            return ProbeResult.failed(vendor + " rejected the credential (HTTP " + status + ") — "
                    + (detail == null ? "check the key and its permissions" : detail));
        }
        if (status == 404) {
            return ProbeResult.failed(vendor + " answered HTTP 404 — "
                    + (detail == null
                            ? "check the endpoint, region, or deployment name"
                            : detail));
        }
        if (status >= 400) {
            return ProbeResult.failed(vendor + " answered HTTP " + status
                    + (detail == null ? "" : " — " + detail));
        }
        List<String> models;
        try {
            models = reader.read(objectMapper.readTree(response.body()));
        } catch (Exception ex) {
            // Authenticated fine but the payload was not what we expected —
            // the credential works, so do not call this a failure.
            return new ProbeResult(true,
                    vendor + " accepted the credential (model list unavailable)", List.of());
        }
        return new ProbeResult(true,
                models.isEmpty()
                        ? vendor + " accepted the credential"
                        : vendor + " accepted the credential — " + models.size()
                                + " model(s) available",
                models);
    }

    /**
     * The vendor's own explanation, dug out of an error body. They do not
     * agree on where it lives: the OpenAI-schema vendors and Anthropic use
     * {@code error.message}, Google nests the same, AWS and Huawei answer
     * with a bare {@code message} or {@code error_msg}.
     *
     * <p>Whatever comes back is SCRUBBED before it travels any further —
     * OpenAI echoes a partially masked key into its own error text, and a
     * message that is about to be stored on the row and shown in a browser is
     * the last place a fragment of a credential belongs.
     *
     * @return null when the body is missing, not JSON, or says nothing useful
     */
    String vendorMessage(String body) {
        if (body == null || body.isBlank()) {
            return null;
        }
        try {
            JsonNode root = objectMapper.readTree(body);
            String message = firstNonBlank(
                    root.path("error").path("message").asText(""),
                    root.path("error").path("error_msg").asText(""),
                    root.path("error_description").asText(""),
                    root.path("error_msg").asText(""),
                    root.path("message").asText(""),
                    root.path("Message").asText(""));
            return message == null ? null : scrub(message);
        } catch (Exception ex) {
            // An HTML error page or a proxy's plain text — nothing safe to quote.
            return null;
        }
    }

    private static String firstNonBlank(String... candidates) {
        for (String candidate : candidates) {
            if (candidate != null && !candidate.isBlank()) {
                return candidate;
            }
        }
        return null;
    }

    /** Key-shaped runs, whitespace, and length — in that order. */
    static String scrub(String message) {
        String cleaned = SECRET_LIKE.matcher(message).replaceAll("***");
        cleaned = cleaned.replaceAll("\\s+", " ").trim();
        return cleaned.length() <= 200 ? cleaned : cleaned.substring(0, 197) + "...";
    }

    private static List<String> ids(JsonNode array, String field) {
        List<String> out = new ArrayList<>();
        if (array != null && array.isArray()) {
            for (JsonNode item : array) {
                String id = item.path(field).asText("");
                if (!id.isBlank()) {
                    out.add(id);
                }
                if (out.size() >= MAX_MODELS) {
                    break;
                }
            }
        }
        return List.copyOf(out);
    }

    private HttpResponse<String> send(HttpRequest request) throws Exception {
        try (HttpClient client = HttpClient.newBuilder()
                .connectTimeout(CONNECT_TIMEOUT)
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build()) {
            return client.send(request, HttpResponse.BodyHandlers.ofString());
        }
    }

    private static String trimSlash(String url) {
        String trimmed = url.trim();
        while (trimmed.endsWith("/")) {
            trimmed = trimmed.substring(0, trimmed.length() - 1);
        }
        return trimmed;
    }

    private static String rootMessage(Throwable ex) {
        Throwable cursor = ex;
        while (cursor.getCause() != null && cursor.getCause() != cursor) {
            cursor = cursor.getCause();
        }
        String message = cursor.getMessage();
        return message == null || message.isBlank() ? cursor.getClass().getSimpleName() : message;
    }

    private static String describe(Kind kind) {
        return ModelProviderCatalog.spec(kind).displayName();
    }
}
