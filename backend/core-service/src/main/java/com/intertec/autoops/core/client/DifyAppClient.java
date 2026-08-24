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

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
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
 * <p>Runs are issued in {@code streaming} mode, and the reason is progress
 * rather than latency. Blocking mode returns one response when the whole
 * workflow is done — which for a research workflow is twenty minutes during
 * which the run screen cannot show anything at all, so an operator watching a
 * motionless spinner reasonably concludes it has hung and cancels work that
 * was about to succeed. Streaming emits an event as each node starts and
 * finishes, which is exactly the progress the operator needs.
 *
 * <p>It also removes a failure mode. A blocking call sits on one idle socket
 * for the whole run and dies on the first read timeout; a streaming one has
 * traffic every few seconds, so the timeout bounds the gap BETWEEN nodes
 * rather than the length of the workflow.
 */
@Component
public class DifyAppClient {

    private static final Logger log = LoggerFactory.getLogger(DifyAppClient.class);

    /** Shared and thread-safe; parses one SSE frame at a time. */
    private static final com.fasterxml.jackson.databind.ObjectMapper MAPPER =
            new com.fasterxml.jackson.databind.ObjectMapper();

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
        return run(appKey, inputs, user, Progress.IGNORED);
    }

    /**
     * A node of the workflow started or finished.
     *
     * <p>Called on the execution thread as each event arrives, so the run's log
     * can be written while the workflow is still going. Implementations must be
     * quick and must not throw — a listener that fails would abort a workflow
     * over a bookkeeping problem.
     *
     * @param title    the node's name as the workflow author wrote it, which is
     *                 what makes the log readable to a customer
     * @param finished false when the node started, true when it completed
     * @param index    which node this is, 1-based, or null if Dify omitted it
     */
    @FunctionalInterface
    public interface Progress {

        Progress IGNORED = (title, finished, index, elapsedMs, failed) -> { };

        void node(String title, boolean finished, Integer index, Long elapsedMs, boolean failed);
    }

    /**
     * Executes the app's published workflow, reporting each node as it happens.
     *
     * @param user an opaque end-user identifier Dify records against the run;
     *             the tenant id goes here so a run can be traced back to the
     *             customer it belonged to from inside Dify's own logs.
     */
    public RunOutcome run(String appKey, Map<String, Object> inputs, String user,
                          Progress progress) {
        requireConfigured();
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("inputs", inputs == null ? Map.of() : inputs);
        payload.put("response_mode", "streaming");
        payload.put("user", user == null || user.isBlank() ? "autoops" : user);

        try {
            RunOutcome outcome = restClient.post()
                    .uri(url("/workflows/run"))
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + appKey)
                    .contentType(MediaType.APPLICATION_JSON)
                    .accept(MediaType.TEXT_EVENT_STREAM)
                    .body(payload)
                    .exchange((request, response) -> consume(response.getBody(), progress), false);
            return outcome == null
                    ? new RunOutcome(false, "unknown",
                            "Dify closed the stream without reporting an outcome",
                            null, null, null, null)
                    : outcome;
        } catch (Exception ex) {
            throw translate(ex, "POST /workflows/run");
        }
    }

    /**
     * Reads Dify's SSE stream and returns the final outcome.
     *
     * <p>Server-sent events are {@code data: {json}} lines separated by blank
     * lines. Anything else — comments, heartbeats, the {@code ping} event Dify
     * sends to hold the connection open — is skipped rather than treated as an
     * error, because a stricter parser would fail a perfectly good run over a
     * keep-alive.
     */
    private RunOutcome consume(java.io.InputStream body, Progress progress) throws java.io.IOException {
        RunOutcome outcome = null;
        try (BufferedReader reader =
                     new BufferedReader(new InputStreamReader(body, StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (!line.startsWith("data:")) {
                    continue;
                }
                String json = line.substring(5).trim();
                if (json.isEmpty() || "[DONE]".equals(json)) {
                    continue;
                }
                JsonNode event;
                try {
                    event = MAPPER.readTree(json);
                } catch (Exception ex) {
                    // One malformed frame must not lose a finished workflow.
                    log.debug("Skipping unparseable Dify event: {}", ex.getMessage());
                    continue;
                }
                RunOutcome fromEvent = handle(event, progress);
                if (fromEvent != null) {
                    outcome = fromEvent;
                }
            }
        }
        return outcome;
    }

    /** @return the outcome when this event ends the workflow, else null */
    private RunOutcome handle(JsonNode event, Progress progress) {
        String type = event.path("event").asText("");
        JsonNode data = event.path("data");

        switch (type) {
            case "node_started", "node_finished" -> {
                boolean finished = "node_finished".equals(type);
                String title = data.path("title").asText("");
                if (title.isBlank()) {
                    title = data.path("node_type").asText("step");
                }
                Integer index = data.path("index").isNumber() ? data.path("index").asInt() : null;
                Long elapsedMs = data.path("elapsed_time").isNumber()
                        ? Math.round(data.path("elapsed_time").asDouble() * 1000) : null;
                boolean failed = finished
                        && !"succeeded".equalsIgnoreCase(data.path("status").asText("succeeded"));
                try {
                    progress.node(title, finished, index, elapsedMs, failed);
                } catch (RuntimeException ex) {
                    // Bookkeeping must never abort a running workflow.
                    log.warn("Progress listener failed on a Dify node event", ex);
                }
            }
            case "workflow_finished" -> {
                // Same envelope shape blocking mode returns, so one parser
                // serves both and they cannot drift apart.
                return outcomeOf(event);
            }
            default -> {
                // workflow_started, ping, text_chunk, tts_message… nothing to do.
            }
        }
        return null;
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
        // A read timeout and a dead host are the same exception type and
        // completely different problems. Reporting both as "unreachable" sent
        // someone to check networking when the truth was that a workflow had
        // simply run longer than the budget — and, worse, "please retry" is
        // exactly the wrong advice: the workflow is still executing in Dify,
        // so retrying starts a second one.
        if (isTimeout(ex)) {
            log.warn("Dify {} exceeded the run budget: {}", what, ex.getMessage());
            throw CoreException.serviceUnavailable("dify_timeout",
                    "The workflow ran longer than the " + properties.getRunTimeout().toMinutes()
                            + "-minute budget and AutoOps stopped waiting. It is probably STILL "
                            + "RUNNING in Dify — check there before starting another, and raise "
                            + "DIFY_RUN_TIMEOUT if this workflow is legitimately this long.");
        }
        log.warn("Dify {} failed: {}", what, ex.getMessage());
        throw CoreException.serviceUnavailable("dify_unavailable",
                "Dify is unreachable, please retry");
    }

    /** A read/connect timeout anywhere in the cause chain. */
    private static boolean isTimeout(Exception ex) {
        for (Throwable cause = ex; cause != null; cause = cause.getCause()) {
            if (cause instanceof java.net.SocketTimeoutException
                    || cause instanceof java.net.http.HttpTimeoutException) {
                return true;
            }
            if (cause.getCause() == cause) {
                break;   // self-referential chain; stop rather than spin
            }
        }
        return false;
    }
}
