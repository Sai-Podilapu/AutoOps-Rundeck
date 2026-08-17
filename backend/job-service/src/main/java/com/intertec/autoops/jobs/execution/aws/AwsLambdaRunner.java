package com.intertec.autoops.jobs.execution.aws;

import com.fasterxml.jackson.databind.JsonNode;
import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.StepRunner;
import org.springframework.stereotype.Component;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Invokes an AWS Lambda function via the Invoke API (SigV4-signed, no SDK) —
 * value format:
 * <pre>
 *   my-function                                (line 1: name or full ARN)
 *   {"orderId": 42}                            (lines after = JSON payload)
 * </pre>
 * Region comes from the step's {@code region}, the ARN, or the AWS
 * integration's stored region — in that order. The tail of the function's
 * CloudWatch log is requested and lands in the run log. Optional step fields:
 * {@code invocationType} (Event = async fire-and-forget), {@code qualifier}
 * (alias or version), {@code endpoint} (override for LocalStack-style
 * emulators).
 */
@Component
public class AwsLambdaRunner implements StepRunner {

    private static final Pattern ARN_REGION =
            Pattern.compile("^arn:aws[a-z-]*:lambda:([a-z0-9-]+):");
    private static final Set<String> INVOCATION_TYPES =
            Set.of("RequestResponse", "Event", "DryRun");

    private final JobProperties properties;

    public AwsLambdaRunner(JobProperties properties) {
        this.properties = properties;
    }

    @Override
    public Set<String> types() {
        return Set.of("awslambda", "lambda");
    }

    @Override
    public StepResult run(StepCommand command) throws Exception {
        String value = command.value() == null ? "" : command.value().trim();
        if (value.isEmpty()) {
            return StepResult.failed("Lambda step has no function — put the function name "
                    + "or ARN on the first line (payload JSON on the lines after)", null, null);
        }
        String[] lines = value.split("\r?\n", 2);
        String function = lines[0].trim();
        String payload = lines.length > 1 ? lines[1].trim() : "";

        JsonNode credentials = command.credentials();
        if (credentials == null || credentials.isNull() || credentials.isMissingNode()) {
            return StepResult.failed("AWS Lambda steps need an AWS cloud integration with "
                    + "credentials — add one under Cloud Integrations", null, null);
        }
        JsonNode data = credentials.path("data");
        String accessKey = first(data, "accessId", "accessKey", "accessKeyId");
        String secretKey = first(data, "secret", "secretKey", "secretAccessKey");
        if (accessKey == null || secretKey == null) {
            return StepResult.failed("AWS integration '" + credentials.path("connection").asText("?")
                    + "' is missing an access key or secret — re-enter its credentials", null, null);
        }
        String sessionToken = first(data, "sessionToken");

        String region = region(command.raw(), function, data);
        if (region == null) {
            return StepResult.failed("No AWS region — set \"region\" on the step, use a full "
                    + "function ARN, or store a region in the AWS integration", null, null);
        }

        String invocationType = command.raw() != null
                ? command.raw().path("invocationType").asText("RequestResponse") : "RequestResponse";
        if (!INVOCATION_TYPES.contains(invocationType)) {
            return StepResult.failed("Unknown invocationType '" + invocationType
                    + "' — use RequestResponse, Event, or DryRun", null, null);
        }

        String endpoint = command.raw() != null && command.raw().hasNonNull("endpoint")
                ? command.raw().get("endpoint").asText()
                : "https://lambda." + region + ".amazonaws.com";
        String qualifier = command.raw() != null
                ? command.raw().path("qualifier").asText(null) : null;
        String path = "/2015-03-31/functions/" + AwsV4.encodeSegment(function) + "/invocations";
        String query = qualifier != null && !qualifier.isBlank()
                ? "Qualifier=" + AwsV4.encodeSegment(qualifier) : null;
        URI uri = URI.create(endpoint + path + (query != null ? "?" + query : ""));

        byte[] body = payload.getBytes(StandardCharsets.UTF_8);
        Map<String, String> signed = AwsV4.headers("POST", uri, region, "lambda",
                accessKey, secretKey, sessionToken, body, Instant.now());

        HttpRequest.Builder request = HttpRequest.newBuilder(uri)
                .timeout(command.timeout())
                .header("X-Amz-Invocation-Type", invocationType)
                .header("X-Amz-Log-Type", "Event".equals(invocationType) ? "None" : "Tail")
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofByteArray(body));
        signed.forEach(request::header);

        try (HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .build()) {
            HttpResponse<String> response =
                    client.send(request.build(), HttpResponse.BodyHandlers.ofString());
            String functionError = response.headers().firstValue("X-Amz-Function-Error")
                    .orElse(null);
            StringBuilder output = new StringBuilder();
            output.append("HTTP ").append(response.statusCode())
                    .append(" · function ").append(function)
                    .append(" · ").append(invocationType).append('\n');
            if (!response.body().isBlank()) {
                output.append(truncate(response.body())).append('\n');
            }
            response.headers().firstValue("X-Amz-Log-Result").ifPresent(encoded -> {
                try {
                    output.append("---- log tail ----\n")
                            .append(new String(Base64.getDecoder().decode(encoded),
                                    StandardCharsets.UTF_8));
                } catch (IllegalArgumentException ignored) {
                    // malformed log header — the invocation result still stands
                }
            });
            if (response.statusCode() >= 400) {
                return StepResult.failed("Lambda invoke failed (HTTP " + response.statusCode()
                        + ")", output.toString(), response.statusCode());
            }
            if (functionError != null) {
                return StepResult.failed("Lambda function returned a " + functionError
                        + " error — payload in the log", output.toString(),
                        response.statusCode());
            }
            return StepResult.ok(output.toString(), response.statusCode());
        }
    }

    private static String region(JsonNode raw, String function, JsonNode data) {
        if (raw != null && raw.hasNonNull("region") && !raw.get("region").asText().isBlank()) {
            return raw.get("region").asText();
        }
        Matcher arn = ARN_REGION.matcher(function);
        if (arn.find()) {
            return arn.group(1);
        }
        String stored = first(data, "region");
        return stored != null && !stored.isBlank() ? stored : null;
    }

    private static String first(JsonNode data, String... keys) {
        for (String key : keys) {
            JsonNode node = data.path(key);
            if (node.isTextual() && !node.asText().isBlank()) {
                return node.asText();
            }
        }
        return null;
    }

    private String truncate(String s) {
        int max = properties.getOutputMaxChars();
        return s.length() <= max ? s : s.substring(0, max) + "\n… output truncated …";
    }
}