package com.intertec.autoops.rundeck.client;

import com.intertec.autoops.rundeck.config.RundeckProperties;
import com.intertec.autoops.rundeck.exception.RundeckException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;
import org.springframework.web.util.UriComponentsBuilder;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * The only place in AutoOps that speaks Rundeck's HTTP API.
 *
 * <p>Every call is a live read or write against a customer's own server —
 * nothing is cached and nothing is mirrored, because the Rundeck console is a
 * peer writer and any copy we kept would be wrong the first time someone used
 * it.
 *
 * <p><strong>Endpoint shapes are pinned to the documented paths</strong>
 * (docs.rundeck.com/docs/api). Two are easy to get wrong and are called out
 * where they are used:
 * <ul>
 *   <li>{@code GET /execution/{id}/abort} — abort is documented as a GET.
 *       Newer servers also accept POST, older ones do not, so GET is what
 *       reaches every version a customer might be running.</li>
 *   <li>{@code GET /job/{id}?format=json} — the single-job export is what
 *       carries the option definitions. {@code /job/{id}/info} is metadata
 *       only and has no options in it, which makes it useless for building a
 *       run form.</li>
 * </ul>
 *
 * <p>The auth token is passed in, never held. This class has no repository and
 * no state; a caller that has not been through {@code ConnectionService} cannot
 * reach a customer's server through it.
 */
@Component
public class RundeckApiClient {

    private static final Logger log = LoggerFactory.getLogger(RundeckApiClient.class);

    private static final String AUTH_HEADER = "X-Rundeck-Auth-Token";

    private static final ParameterizedTypeReference<Map<String, Object>> MAP =
            new ParameterizedTypeReference<>() {
            };

    private static final ParameterizedTypeReference<List<Map<String, Object>>> LIST =
            new ParameterizedTypeReference<>() {
            };

    private final RestClient upstream;
    private final RundeckProperties properties;

    public RundeckApiClient(@Qualifier("upstreamRestClient") RestClient upstream,
                            RundeckProperties properties) {
        this.upstream = upstream;
        this.properties = properties;
    }

    /**
     * Everything needed to address one Rundeck server, assembled by the caller
     * from a decrypted connection row. A record rather than the entity, so the
     * ciphertext and the tenant never travel down here.
     */
    public record Target(String baseUrl, int apiVersion, String token) {
    }

    /** What {@code /system/info} tells us about a server we just reached. */
    public record SystemInfo(String version, String serverName, String apiVersionReported) {
    }

    // ---------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------

    /**
     * The cheapest authenticated call Rundeck offers — used as the credential
     * check. It proves three things at once: the host resolves, TLS completes,
     * and the token is accepted.
     */
    public SystemInfo systemInfo(Target target) {
        Map<String, Object> body = getMap(target, plain(uri(target, "/system/info")));
        Map<String, Object> system = asMap(body.get("system"));
        Map<String, Object> rundeck = asMap(system.get("rundeck"));
        return new SystemInfo(
                str(rundeck.get("version")),
                str(rundeck.get("serverName")) != null ? str(rundeck.get("serverName"))
                        : str(rundeck.get("node")),
                str(rundeck.get("apiversion")));
    }

    public List<Map<String, Object>> listProjects(Target target) {
        return getList(target, plain(uri(target, "/projects")));
    }

    /** Note the SINGULAR {@code /project/} segment — {@code /projects} is the list. */
    public List<Map<String, Object>> listJobs(Target target, String project) {
        return getList(target, expand(uri(target, "/project/{project}/jobs"), project));
    }

    /** Metadata only: id, name, group, project, href. No options. */
    public Map<String, Object> jobInfo(Target target, String jobId) {
        return getMap(target, expand(uri(target, "/job/{id}/info"), jobId));
    }

    /**
     * The full job definition, which is the only place the OPTIONS live — the
     * run form is built from this. Rundeck returns a one-element array here
     * (the export format is a list of jobs even for a single id).
     */
    public Map<String, Object> jobDefinition(Target target, String jobId) {
        URI exportUri = expand(uri(target, "/job/{id}")
                .queryParam("format", "json"), jobId);
        List<Map<String, Object>> definitions = getList(target, exportUri);
        if (definitions.isEmpty()) {
            throw RundeckException.notFound("rundeck_job_not_found",
                    "Rundeck has no job with id " + jobId);
        }
        return definitions.get(0);
    }

    public Map<String, Object> execution(Target target, long executionId) {
        return getMap(target, expand(uri(target, "/execution/{id}"), executionId));
    }

    /**
     * A window of the execution log. {@code offset} is Rundeck's byte offset
     * from the previous poll — the console passes back whatever the last
     * response reported, which is how tailing works without re-reading the
     * whole log every second.
     */
    public Map<String, Object> executionOutput(Target target, long executionId,
                                               String offset, Integer maxLines) {
        int lines = maxLines == null
                ? properties.getUpstream().getMaxLogLines()
                : Math.min(maxLines, properties.getUpstream().getMaxLogLines());
        UriComponentsBuilder builder = uri(target, "/execution/{id}/output")
                .queryParam("maxlines", lines);
        if (offset != null && !offset.isBlank()) {
            builder.queryParam("offset", offset);
        }
        return getMap(target, expand(builder, executionId));
    }

    public Map<String, Object> projectExecutions(Target target, String project,
                                                 int max, int offset) {
        return getMap(target, expand(uri(target, "/project/{project}/executions")
                .queryParam("max", max)
                .queryParam("offset", offset), project));
    }

    /**
     * The node inventory — the one Rundeck capability AutoOps has no native
     * equivalent for. Returns a map keyed by node name, each value the node's
     * attributes (hostname, osFamily, tags, ...).
     */
    public Map<String, Object> projectNodes(Target target, String project, String filter) {
        UriComponentsBuilder builder = uri(target, "/project/{project}/resources");
        if (filter != null && !filter.isBlank()) {
            builder.queryParam("filter", filter);
        }
        return getMap(target, expand(builder, project));
    }

    // ---------------------------------------------------------------------
    // Provisioning + ad-hoc execution (the job-service replacement path)
    // ---------------------------------------------------------------------

    /**
     * Create a Rundeck project if it does not already exist.
     *
     * <p>Idempotent by design: Rundeck answers **409** when the project is
     * there, and that is the desired state, so it is swallowed. Treating it as
     * a failure would make every step after the first one in a project fail.
     */
    public void ensureProject(Target target, String project) {
        try {
            exchange(target, "POST", plain(uri(target, "/projects")),
                    Map.of("name", project), MAP);
        } catch (RundeckException ex) {
            if ("rundeck_conflict".equals(ex.getError())) {
                return;
            }
            throw ex;
        }
    }

    /**
     * Ad-hoc command — one shell command, dispatched across the node filter.
     *
     * <p>Both {@code exec} and {@code command} carry the same value. Rundeck
     * has used each name across API versions and reads whichever it knows;
     * sending one and guessing wrong produces a request that is accepted and
     * executes nothing, which is far worse than a rejected one.
     */
    public Map<String, Object> runCommand(Target target, String project, String command,
                                          String filter, Integer threadCount,
                                          Boolean keepGoing, String asUser) {
        Map<String, Object> body = new HashMap<>();
        body.put("exec", command);
        body.put("command", command);
        applyDispatch(body, filter, threadCount, keepGoing, asUser);
        return exchange(target, "POST",
                expand(uri(target, "/project/{project}/run/command"), project), body, MAP);
    }

    /**
     * Ad-hoc script — the script body is uploaded and run under an interpreter.
     *
     * <p>Multipart, because that is the only shape this endpoint accepts for
     * the script itself. {@code scriptInterpreter} is what makes one endpoint
     * serve python, bash and anything else with a shebang-less body: the
     * translator picks the interpreter per AutoOps step type.
     */
    public Map<String, Object> runScript(Target target, String project, String script,
                                         String interpreter, String argString,
                                         String fileExtension, String filter,
                                         Integer threadCount, Boolean keepGoing,
                                         String asUser) {
        MultiValueMap<String, Object> form = new LinkedMultiValueMap<>();
        // A ByteArrayResource with a filename is what makes this a FILE part
        // rather than a text field; without the filename override Spring sends
        // it as a plain form value and Rundeck reports no script was supplied.
        form.add("scriptFile", new ByteArrayResource(script.getBytes(StandardCharsets.UTF_8)) {
            @Override
            public String getFilename() {
                return "autoops-step" + (fileExtension == null ? ".sh" : "." + fileExtension);
            }
        });
        if (interpreter != null && !interpreter.isBlank()) {
            form.add("scriptInterpreter", interpreter);
        }
        if (argString != null && !argString.isBlank()) {
            form.add("argString", argString);
        }
        if (fileExtension != null && !fileExtension.isBlank()) {
            form.add("fileExtension", fileExtension);
        }
        if (filter != null && !filter.isBlank()) {
            form.add("filter", filter);
        }
        if (threadCount != null) {
            form.add("nodeThreadcount", String.valueOf(threadCount));
        }
        if (keepGoing != null) {
            form.add("nodeKeepgoing", String.valueOf(keepGoing));
        }
        if (asUser != null && !asUser.isBlank()) {
            form.add("asUser", asUser);
        }
        return multipart(target,
                expand(uri(target, "/project/{project}/run/script"), project), form);
    }

    private static void applyDispatch(Map<String, Object> body, String filter,
                                      Integer threadCount, Boolean keepGoing, String asUser) {
        if (filter != null && !filter.isBlank()) {
            body.put("filter", filter);
        }
        if (threadCount != null) {
            body.put("nodeThreadcount", threadCount);
        }
        if (keepGoing != null) {
            body.put("nodeKeepgoing", keepGoing);
        }
        if (asUser != null && !asUser.isBlank()) {
            body.put("asUser", asUser);
        }
    }

    // ---------------------------------------------------------------------
    // Writes
    // ---------------------------------------------------------------------

    /**
     * Dispatch. {@code filter} is Rundeck's node-filter string
     * ({@code tags: web+prod}); null means the job's own configured filter,
     * which is what a caller who does not want to override should send.
     */
    public Map<String, Object> runJob(Target target, String jobId,
                                      Map<String, String> options, String filter,
                                      String logLevel, String asUser) {
        Map<String, Object> body = new HashMap<>();
        if (options != null && !options.isEmpty()) {
            body.put("options", options);
        }
        if (filter != null && !filter.isBlank()) {
            body.put("filter", filter);
        }
        if (logLevel != null && !logLevel.isBlank()) {
            body.put("loglevel", logLevel);
        }
        // asUser needs `runAs` permission on the Rundeck side. Sent only when
        // the caller explicitly asked, so a server without that grant is not
        // handed a request it must refuse.
        if (asUser != null && !asUser.isBlank()) {
            body.put("asUser", asUser);
        }
        return exchange(target, "POST", expand(uri(target, "/job/{id}/run"), jobId), body,
                MAP);
    }

    /**
     * Abort a running execution.
     *
     * <p>GET, deliberately. Rundeck documents abort as a GET and has since the
     * early API versions; POST works on recent servers only. Since a customer
     * may be running anything from v3 upward, the documented verb is the one
     * that always lands.
     */
    public Map<String, Object> abort(Target target, long executionId) {
        return exchange(target, "GET",
                expand(uri(target, "/execution/{id}/abort"), executionId), null, MAP);
    }

    // ---------------------------------------------------------------------
    // Transport
    // ---------------------------------------------------------------------

    private UriComponentsBuilder uri(Target target, String path) {
        String base = target.baseUrl().endsWith("/")
                ? target.baseUrl().substring(0, target.baseUrl().length() - 1)
                : target.baseUrl();
        return UriComponentsBuilder.fromUriString(base + "/api/" + target.apiVersion() + path);
    }

    /**
     * Expand path variables, THEN encode.
     *
     * <p>Order matters and is the reason these two helpers exist rather than a
     * bare {@code buildAndExpand}. Rundeck project names routinely contain
     * spaces and job groups contain slashes; encoding before expansion would
     * leave those raw in the path, and the request would either 404 or address
     * a different resource entirely.
     */
    private static URI expand(UriComponentsBuilder builder, Object... vars) {
        return builder.buildAndExpand(vars).encode().toUri();
    }

    private static URI plain(UriComponentsBuilder builder) {
        return builder.build().encode().toUri();
    }

    private Map<String, Object> getMap(Target target, URI uri) {
        return exchange(target, "GET", uri, null, MAP);
    }

    private List<Map<String, Object>> getList(Target target, URI uri) {
        List<Map<String, Object>> body = exchange(target, "GET", uri, null, LIST);
        return body == null ? List.of() : body;
    }

    /** Multipart POST — only the ad-hoc script endpoint needs this shape. */
    private Map<String, Object> multipart(Target target, URI uri,
                                          MultiValueMap<String, Object> form) {
        try {
            return upstream.post()
                    .uri(uri)
                    .header(AUTH_HEADER, target.token())
                    .contentType(MediaType.MULTIPART_FORM_DATA)
                    .accept(MediaType.APPLICATION_JSON)
                    .body(form)
                    .retrieve()
                    .body(MAP);
        } catch (RestClientResponseException ex) {
            throw translate(ex, uri);
        } catch (Exception ex) {
            log.warn("Rundeck upstream unreachable at {}: {}", uri.getHost(), ex.getMessage());
            throw RundeckException.upstream("rundeck_unreachable",
                    "Could not reach the execution engine — " + rootMessage(ex));
        }
    }

    private <T> T exchange(Target target, String method, URI uri, Object body,
                           ParameterizedTypeReference<T> type) {
        try {
            RestClient.RequestBodySpec spec = upstream
                    .method(HttpMethod.valueOf(method))
                    .uri(uri)
                    .header(AUTH_HEADER, target.token())
                    .accept(MediaType.APPLICATION_JSON);
            // body(...) returns a NEW spec — assigning it is the whole point.
            // Dropping the return value silently sends an empty request.
            RestClient.RequestHeadersSpec<?> ready = body != null
                    ? spec.contentType(MediaType.APPLICATION_JSON).body(body)
                    : spec;
            return ready.retrieve().body(type);
        } catch (RestClientResponseException ex) {
            throw translate(ex, uri);
        } catch (RundeckException ex) {
            throw ex;
        } catch (Exception ex) {
            // Connect refused, DNS failure, TLS failure, read timeout. The host
            // is named because "unreachable" without it is unactionable, but the
            // token never appears — it is only ever in a header.
            log.warn("Rundeck upstream unreachable at {}: {}", uri.getHost(), ex.getMessage());
            throw RundeckException.upstream("rundeck_unreachable",
                    "Could not reach the Rundeck server at " + uri.getHost()
                            + " — " + rootMessage(ex));
        }
    }

    /**
     * Rundeck's own error shape is {@code {"error":true,"errorCode":...,
     * "message":...}}. Its message is the useful part; the status alone tells a
     * user nothing about which job or which permission was the problem.
     */
    private RundeckException translate(RestClientResponseException ex, URI uri) {
        String detail = rundeckMessage(ex.getResponseBodyAsString());
        int status = ex.getStatusCode().value();
        if (status == 401 || status == 403) {
            return RundeckException.upstream("rundeck_unauthorized",
                    "Rundeck rejected the stored API token"
                            + (detail != null ? " — " + detail : "")
                            + ". Check the token has not expired and its ACL grants this action.");
        }
        if (status == 404) {
            return RundeckException.notFound("rundeck_not_found",
                    detail != null ? detail : "Rundeck has no such job, project or execution");
        }
        if (status == 409) {
            return RundeckException.conflict("rundeck_conflict",
                    detail != null ? detail : "Rundeck refused the request as conflicting");
        }
        log.warn("Rundeck returned {} for {}: {}", status, uri.getPath(), detail);
        return RundeckException.upstream("rundeck_error",
                "Rundeck returned " + status + (detail != null ? " — " + detail : ""));
    }

    /** Pulls {@code message} out of a Rundeck JSON error body, if there is one. */
    private static String rundeckMessage(String body) {
        if (body == null || body.isBlank()) {
            return null;
        }
        int key = body.indexOf("\"message\"");
        if (key < 0) {
            // Not JSON, or not Rundeck's shape (an HTML login page, typically —
            // which is what a wrong base URL looks like). Keep a short prefix.
            return body.length() > 180 ? body.substring(0, 180) + "…" : body;
        }
        int start = body.indexOf('"', body.indexOf(':', key) + 1);
        int end = start < 0 ? -1 : body.indexOf('"', start + 1);
        return start < 0 || end < 0 ? null : body.substring(start + 1, end);
    }

    private static String rootMessage(Throwable ex) {
        Throwable cursor = ex;
        while (cursor.getCause() != null && cursor.getCause() != cursor) {
            cursor = cursor.getCause();
        }
        return cursor.getMessage() != null ? cursor.getMessage() : cursor.getClass().getSimpleName();
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> asMap(Object value) {
        return value instanceof Map ? (Map<String, Object>) value : Map.of();
    }

    private static String str(Object value) {
        return value == null ? null : String.valueOf(value);
    }
}
