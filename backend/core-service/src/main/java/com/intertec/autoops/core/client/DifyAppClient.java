package com.intertec.autoops.core.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.intertec.autoops.core.config.DifyProperties;
import com.intertec.autoops.core.exception.CoreException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Talks to Dify's <b>Service API</b> ({@code /v1}) with a per-app {@code app-…}
 * key.
 *
 * <p>Deliberately separate from {@link DifyClient}, which speaks
 * {@code /console/api} with the workspace token. They differ in base path, in
 * credential, and in blast radius: the console token can delete every app in
 * the workspace, while an app key can only see and run the one app it belongs
 * to. Merging them behind one class would mean one careless call reaching the
 * console with the wrong intent.
 *
 * <p>Runs are issued in {@code blocking} mode. The streaming mode exists for a
 * UI that renders tokens as they arrive; this client is called from the
 * execution pool, where nothing is watching until the run finishes, and a
 * single response is far easier to record faithfully than a reassembled SSE
 * stream.
 */
@Component
public class DifyAppClient {

    private static final Logger log = LoggerFactory.getLogger(DifyAppClient.class);

    /** Dify mounts the Service API here — NOT under /console/api. */
    private static final String SERVICE = "/v1";

    private final DifyProperties properties;
    private final RestClient restClient;

    public DifyAppClient(DifyProperties properties) {
        this.properties = properties;
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout((int) properties.getConnectTimeout().toMillis());
        // A workflow run is the long call here, not a console read, so this
        // client gets the run timeout rather than DifyClient's 30s.
        factory.setReadTimeout((int) properties.getRunTimeout().toMillis());
        this.restClient = RestClient.builder().requestFactory(factory).build();
    }

    /**
     * Only the base URL is needed to reach the Service API — the console token
     * is irrelevant here, since every call carries an app key instead. A
     * deployment with DIFY_BASE_URL but no DIFY_API_KEY can still run
     * workflows, and refusing that would be wrong.
     */
    public boolean isConfigured() {
        return !properties.normalizedBaseUrl().isEmpty();
    }

    public void requireConfigured() {
        if (!isConfigured()) {
            throw CoreException.serviceUnavailable("dify_not_configured",
                    "Dify is not connected. Set DIFY_BASE_URL on core-service and restart it.");
        }
    }

    /** App name and description, as published in Dify. */
    public JsonNode info(String appKey) {
        return get(appKey, "/info");
    }

    /**
     * The published input form: which variables the workflow expects, their
     * labels, types and whether they are required. This is the source of the
     * form the customer fills in, which is why nothing about a workflow's
     * inputs is ever typed by hand into AutoOps.
     */
    public JsonNode parameters(String appKey) {
        return get(appKey, "/parameters");
    }

    /** One workflow run's outcome, flattened out of Dify's envelope. */
    public record RunOutcome(boolean success, String status, String error,
                             String outputs, Long elapsedMs, Integer totalSteps,
                             String workflowRunId) {
    }

    /**
     * Executes the app's published workflow.
     *
     * @param user an opaque end-user identifier Dify records against the run;
     *             the tenant id goes here so a run can be traced back to the
     *             customer it belonged to from inside Dify's own logs.
     */
    public RunOutcome run(String appKey, Map<String, Object> inputs, String user) {
        requireConfigured();
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("inputs", inputs == null ? Map.of() : inputs);
        payload.put("response_mode", "blocking");
        payload.put("user", user == null || user.isBlank() ? "autoops" : user);
        JsonNode body;
        try {
            body = restClient.post()
                    .uri(url("/workflows/run"))
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + appKey)
                    .contentType(MediaType.APPLICATION_JSON)
                    .accept(MediaType.APPLICATION_JSON)
                    .body(payload)
                    .retrieve()
                    .body(JsonNode.class);
        } catch (Exception ex) {
            throw translate(ex, "POST /workflows/run");
        }
        return outcomeOf(body);
    }

    /**
     * Dify reports a failed workflow inside a 200 response — {@code data.status}
     * is {@code failed} and {@code data.error} carries the reason. Reading only
     * the HTTP status would record every failed run as a success.
     */
    static RunOutcome outcomeOf(JsonNode body) {
        if (body == null) {
            return new RunOutcome(false, "unknown", "Dify returned an empty response",
                    null, null, null, null);
        }
        JsonNode data = body.path("data");
        String status = data.path("status").asText("");
        String error = data.path("error").isNull() ? null
                : data.path("error").asText(null);
        JsonNode outputs = data.path("outputs");
        Long elapsedMs = data.path("elapsed_time").isNumber()
                ? Math.round(data.path("elapsed_time").asDouble() * 1000) : null;
        Integer totalSteps = data.path("total_steps").isNumber()
                ? data.path("total_steps").asInt() : null;
        boolean success = "succeeded".equalsIgnoreCase(status);
        return new RunOutcome(success, status.isEmpty() ? "unknown" : status,
                success ? null : (error == null || error.isBlank()
                        ? "Dify reported status '" + status + "'" : error),
                outputs.isMissingNode() || outputs.isNull() ? null : outputs.toString(),
                elapsedMs, totalSteps, data.path("id").asText(null));
    }

    private JsonNode get(String appKey, String path) {
        requireConfigured();
        try {
            return restClient.get()
                    .uri(url(path))
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + appKey)
                    .accept(MediaType.APPLICATION_JSON)
                    .retrieve()
                    .body(JsonNode.class);
        } catch (Exception ex) {
            throw translate(ex, "GET " + path);
        }
    }

    private String url(String path) {
        return properties.normalizedBaseUrl() + SERVICE + path;
    }

    private CoreException translate(Exception ex, String what) {
        if (ex instanceof RestClientResponseException http) {
            int status = http.getStatusCode().value();
            if (status == 401 || status == 403) {
                // The APP key is wrong or revoked — an operator problem. Never
                // surface it as 401, which the console reads as "your session
                // expired" and acts on by logging the user out.
                log.error("Dify rejected an app key on {} — check the DIFY_WF_* value", what);
                throw CoreException.badGateway("dify_app_unauthorized",
                        "Dify rejected the key for this workflow. Check its DIFY_WF_ value.");
            }
            if (status == 404) {
                throw CoreException.notFound("dify_not_found",
                        "Dify has no published workflow for this key");
            }
            log.warn("Dify {} failed: {} {}", what, status, http.getResponseBodyAsString());
            throw CoreException.badGateway("dify_error",
                    "Dify rejected the request (" + status + ")");
        }
        log.warn("Dify {} failed: {}", what, ex.getMessage());
        throw CoreException.serviceUnavailable("dify_unavailable",
                "Dify is unreachable, please retry");
    }
}
