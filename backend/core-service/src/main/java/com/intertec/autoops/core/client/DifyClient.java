package com.intertec.autoops.core.client;

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

import java.io.InputStream;
import java.util.Map;

/**
 * Talks to the Dify console API on the server's behalf.
 *
 * <p>Every call carries the workspace token from {@link DifyProperties}, which
 * is why this class exists at all: that token is far too privileged to hand to
 * a browser, so the console calls AutoOps and AutoOps calls Dify.
 *
 * <p>Errors are translated rather than passed through raw. A Dify 401 means
 * OUR key is wrong — an operator problem, not the caller's — so it surfaces as
 * a 502 with a message that says so, instead of a 401 the console would
 * misread as "your AutoOps session expired" and act on by logging the user out.
 */
@Component
public class DifyClient {

    private static final Logger log = LoggerFactory.getLogger(DifyClient.class);

    /** Dify mounts its console API under this prefix. */
    private static final String CONSOLE = "/console/api";

    private final DifyProperties properties;
    private final RestClient restClient;

    public DifyClient(DifyProperties properties) {
        this.properties = properties;
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout((int) properties.getConnectTimeout().toMillis());
        factory.setReadTimeout((int) properties.getReadTimeout().toMillis());
        this.restClient = RestClient.builder().requestFactory(factory).build();
    }

    public boolean isConfigured() {
        return properties.isConfigured();
    }

    /**
     * Refuses early and legibly when Dify was never wired up, so the first
     * symptom is "Dify is not configured", not a null-pointer 500.
     */
    public void requireConfigured() {
        if (!properties.isConfigured()) {
            throw CoreException.serviceUnavailable("dify_not_configured",
                    "Dify is not connected. Set DIFY_BASE_URL and DIFY_API_KEY on "
                            + "core-service and restart it.");
        }
    }

    public Object get(String path) {
        requireConfigured();
        try {
            return restClient.get()
                    .uri(url(path))
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + properties.getApiKey())
                    .accept(MediaType.APPLICATION_JSON)
                    .retrieve()
                    .body(Object.class);
        } catch (Exception ex) {
            throw translate(ex, "GET " + path);
        }
    }

    public Object post(String path, Object body) {
        requireConfigured();
        try {
            var request = restClient.post()
                    .uri(url(path))
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + properties.getApiKey())
                    .contentType(MediaType.APPLICATION_JSON)
                    .accept(MediaType.APPLICATION_JSON);
            return (body == null ? request.body(Map.of()) : request.body(body))
                    .retrieve()
                    .body(Object.class);
        } catch (Exception ex) {
            throw translate(ex, "POST " + path);
        }
    }

    public void delete(String path) {
        requireConfigured();
        try {
            restClient.delete()
                    .uri(url(path))
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + properties.getApiKey())
                    .retrieve()
                    .toBodilessEntity();
        } catch (Exception ex) {
            throw translate(ex, "DELETE " + path);
        }
    }

    /**
     * Opens a streaming POST and hands back the raw body for relaying.
     *
     * <p>A workflow run is server-sent events: the caller needs the first token
     * as soon as Dify emits it, so this deliberately does NOT buffer. The
     * caller owns closing the stream.
     */
    public InputStream stream(String path, Object body) {
        requireConfigured();
        try {
            return restClient.post()
                    .uri(url(path))
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + properties.getApiKey())
                    .contentType(MediaType.APPLICATION_JSON)
                    .accept(MediaType.TEXT_EVENT_STREAM)
                    .body(body == null ? Map.of() : body)
                    .exchange((request, response) -> response.getBody(), false);
        } catch (Exception ex) {
            throw translate(ex, "STREAM " + path);
        }
    }

    private String url(String path) {
        return properties.normalizedBaseUrl() + CONSOLE + path;
    }

    private CoreException translate(Exception ex, String what) {
        if (ex instanceof RestClientResponseException http) {
            int status = http.getStatusCode().value();
            if (status == 401 || status == 403) {
                // OUR credential, not the caller's session.
                log.error("Dify rejected the AutoOps workspace token on {} — check DIFY_API_KEY",
                        what);
                throw CoreException.badGateway("dify_unauthorized",
                        "Dify rejected the configured API key. Check DIFY_API_KEY.");
            }
            if (status == 404) {
                throw CoreException.notFound("dify_not_found", "Dify has no such resource");
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
