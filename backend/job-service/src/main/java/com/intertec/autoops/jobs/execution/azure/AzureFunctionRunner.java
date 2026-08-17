package com.intertec.autoops.jobs.execution.azure;

import com.fasterxml.jackson.databind.JsonNode;
import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.StepRunner;
import org.springframework.stereotype.Component;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Locale;
import java.util.Set;

/**
 * Invokes an Azure Function over its HTTP trigger — value format:
 * <pre>
 *   https://my-app.azurewebsites.net/api/ProcessOrder   (line 1: [METHOD] url)
 *   {"orderId": 42}                                     (lines after = body)
 * </pre>
 * The method defaults to POST when a body is present, GET otherwise. The
 * function key comes from the AZURE integration's {@code functionKey}
 * credential field (sent as {@code x-functions-key}) or a {@code ?code=}
 * already in the URL; anonymous-auth functions need neither. 2xx/3xx =
 * success, response status + body land in the run log.
 */
@Component
public class AzureFunctionRunner implements StepRunner {

    private static final Set<String> METHODS =
            Set.of("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD");

    private final JobProperties properties;

    public AzureFunctionRunner(JobProperties properties) {
        this.properties = properties;
    }

    @Override
    public Set<String> types() {
        return Set.of("azurefn", "azurefunction");
    }

    @Override
    public StepResult run(StepCommand command) throws Exception {
        String value = command.value() == null ? "" : command.value().trim();
        if (value.isEmpty()) {
            return StepResult.failed("Azure Function step has no URL — put the function's "
                    + "HTTP trigger URL on the first line (JSON body on the lines after)",
                    null, null);
        }
        String[] lines = value.split("\r?\n", 2);
        String[] firstLine = lines[0].trim().split("\\s+", 2);
        String body = lines.length > 1 ? lines[1].trim() : "";
        String method;
        String url;
        if (firstLine.length == 2 && METHODS.contains(firstLine[0].toUpperCase(Locale.ROOT))) {
            method = firstLine[0].toUpperCase(Locale.ROOT);
            url = firstLine[1].trim();
        } else {
            method = body.isEmpty() ? "GET" : "POST";
            url = lines[0].trim();
        }
        if (!url.startsWith("https://") && !url.startsWith("http://")) {
            return StepResult.failed("Azure Function URL must be http(s) — got '" + url + "'",
                    null, null);
        }

        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create(url))
                .timeout(command.timeout())
                .method(method, body.isEmpty()
                        ? HttpRequest.BodyPublishers.noBody()
                        : HttpRequest.BodyPublishers.ofString(body));
        if (!body.isEmpty()) {
            request.header("Content-Type", "application/json");
        }
        String functionKey = functionKey(command.credentials());
        if (functionKey != null) {
            request.header("x-functions-key", functionKey);
        }

        try (HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build()) {
            HttpResponse<String> response =
                    client.send(request.build(), HttpResponse.BodyHandlers.ofString());
            String output = "HTTP " + response.statusCode() + " · " + method + ' ' + stripCode(url)
                    + '\n' + truncate(response.body());
            if (response.statusCode() == 401 || response.statusCode() == 403) {
                return StepResult.failed("Function rejected the call (HTTP "
                        + response.statusCode() + ") — check the functionKey on the AZURE "
                        + "integration or the ?code= in the URL", output,
                        response.statusCode());
            }
            return response.statusCode() < 400
                    ? StepResult.ok(output, response.statusCode())
                    : StepResult.failed("Function returned HTTP " + response.statusCode(),
                            output, response.statusCode());
        }
    }

    private static String functionKey(JsonNode credentials) {
        if (credentials == null || credentials.isNull() || credentials.isMissingNode()) {
            return null;
        }
        JsonNode data = credentials.path("data");
        for (String key : new String[]{"functionKey", "hostKey", "code"}) {
            JsonNode node = data.path(key);
            if (node.isTextual() && !node.asText().isBlank()) {
                return node.asText();
            }
        }
        return null;
    }

    /** Never echo a ?code= secret into the run log. */
    private static String stripCode(String url) {
        return url.replaceAll("([?&]code=)[^&]+", "$1***");
    }

    private String truncate(String s) {
        if (s == null) {
            return "";
        }
        int max = properties.getOutputMaxChars();
        return s.length() <= max ? s : s.substring(0, max) + "\n… output truncated …";
    }
}