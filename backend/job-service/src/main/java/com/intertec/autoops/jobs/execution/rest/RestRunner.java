package com.intertec.autoops.jobs.execution.rest;

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
 * Calls an HTTP endpoint — value format:
 * <pre>
 *   https://api.example.com/health              (GET)
 *   POST https://api.example.com/deploy
 *   {"env":"prod"}                              (lines after the first = JSON body)
 * </pre>
 * 2xx/3xx = success; the response status + body land in the run log.
 */
@Component
public class RestRunner implements StepRunner {

    private static final Set<String> METHODS =
            Set.of("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD");

    private final JobProperties properties;

    public RestRunner(JobProperties properties) {
        this.properties = properties;
    }

    @Override
    public Set<String> types() {
        return Set.of("rest");
    }

    @Override
    public StepResult run(StepCommand command) throws Exception {
        String value = command.value() == null ? "" : command.value().trim();
        if (value.isEmpty()) {
            return StepResult.failed("REST step has no URL — e.g. \"GET https://api.example.com/health\"",
                    null, null);
        }
        String[] lines = value.split("\r?\n", 2);
        String[] firstLine = lines[0].trim().split("\\s+", 2);
        String method;
        String url;
        if (firstLine.length == 2 && METHODS.contains(firstLine[0].toUpperCase(Locale.ROOT))) {
            method = firstLine[0].toUpperCase(Locale.ROOT);
            url = firstLine[1].trim();
        } else {
            method = "GET";
            url = lines[0].trim();
        }
        String body = lines.length > 1 ? lines[1].trim() : "";

        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create(url))
                .timeout(command.timeout())
                .method(method, body.isEmpty()
                        ? HttpRequest.BodyPublishers.noBody()
                        : HttpRequest.BodyPublishers.ofString(body));
        if (!body.isEmpty()) {
            request.header("Content-Type", "application/json");
        }
        try (HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build()) {
            HttpResponse<String> response =
                    client.send(request.build(), HttpResponse.BodyHandlers.ofString());
            String output = "HTTP " + response.statusCode() + "\n"
                    + truncate(response.body(), properties.getOutputMaxChars());
            return response.statusCode() < 400
                    ? StepResult.ok(output, response.statusCode())
                    : StepResult.failed("Endpoint returned HTTP " + response.statusCode(),
                            output, response.statusCode());
        }
    }

    private static String truncate(String s, int max) {
        if (s == null) {
            return "";
        }
        return s.length() <= max ? s : s.substring(0, max) + "\n… output truncated …";
    }
}
