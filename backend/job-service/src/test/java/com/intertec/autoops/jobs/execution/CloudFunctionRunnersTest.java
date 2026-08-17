package com.intertec.autoops.jobs.execution;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.aws.AwsLambdaRunner;
import com.intertec.autoops.jobs.execution.aws.AwsV4;
import com.intertec.autoops.jobs.execution.azure.AzureFunctionRunner;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Lambda + Azure Function runners against a local JDK HttpServer standing in
 * for the cloud endpoint (the Lambda runner takes an {@code endpoint}
 * override — the same hook LocalStack users get).
 */
class CloudFunctionRunnersTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private static JobProperties properties;
    private static AwsLambdaRunner lambdaRunner;
    private static AzureFunctionRunner azureRunner;
    private static HttpServer server;
    private static String base;
    private static final AtomicReference<com.sun.net.httpserver.Headers> lastHeaders =
            new AtomicReference<>();

    @BeforeAll
    static void setUp() throws Exception {
        properties = new JobProperties();
        properties.setDefaultStepTimeout(Duration.ofSeconds(15));
        lambdaRunner = new AwsLambdaRunner(properties);
        azureRunner = new AzureFunctionRunner(properties);

        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/2015-03-31/functions/order-fn/invocations", exchange -> {
            lastHeaders.set(exchange.getRequestHeaders());
            exchange.getResponseHeaders().add("X-Amz-Log-Result",
                    Base64.getEncoder().encodeToString(
                            "START RequestId: 1\nEND".getBytes(StandardCharsets.UTF_8)));
            respond(exchange, 200, "{\"ok\":true}");
        });
        server.createContext("/2015-03-31/functions/broken-fn/invocations", exchange -> {
            exchange.getResponseHeaders().add("X-Amz-Function-Error", "Unhandled");
            respond(exchange, 200, "{\"errorMessage\":\"boom\"}");
        });
        server.createContext("/api/ProcessOrder", exchange -> {
            lastHeaders.set(exchange.getRequestHeaders());
            respond(exchange, 200, "processed");
        });
        server.createContext("/api/Locked", exchange -> respond(exchange, 401, "unauthorized"));
        server.start();
        base = "http://127.0.0.1:" + server.getAddress().getPort();
    }

    @AfterAll
    static void tearDown() {
        server.stop(0);
    }

    // ------ SigV4 ------

    @Test
    void sigV4ProducesAWellFormedAuthorizationHeader() {
        Map<String, String> headers = AwsV4.headers("POST",
                URI.create("https://lambda.eu-west-1.amazonaws.com/2015-03-31/functions/f/invocations"),
                "eu-west-1", "lambda", "AKIAEXAMPLE", "secret", null,
                "{}".getBytes(StandardCharsets.UTF_8),
                Instant.parse("2026-07-26T12:00:00Z"));
        assertEquals("20260726T120000Z", headers.get("x-amz-date"));
        String auth = headers.get("authorization");
        assertTrue(auth.startsWith(
                "AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/20260726/eu-west-1/lambda/aws4_request"));
        assertTrue(auth.contains("SignedHeaders=host;x-amz-date"));
        assertTrue(auth.matches(".*Signature=[0-9a-f]{64}$"));
    }

    @Test
    void sigV4SignsTheSessionTokenWhenPresent() {
        Map<String, String> headers = AwsV4.headers("POST",
                URI.create("https://lambda.eu-west-1.amazonaws.com/x"),
                "eu-west-1", "lambda", "AKIA", "secret", "the-token",
                new byte[0], Instant.parse("2026-07-26T12:00:00Z"));
        assertEquals("the-token", headers.get("x-amz-security-token"));
        assertTrue(headers.get("authorization")
                .contains("SignedHeaders=host;x-amz-date;x-amz-security-token"));
    }

    @Test
    void arnSegmentsAreRfc3986Encoded() {
        assertEquals("arn%3Aaws%3Alambda%3Aeu-west-1%3A123%3Afunction%3Afn",
                AwsV4.encodeSegment("arn:aws:lambda:eu-west-1:123:function:fn"));
    }

    // ------ awslambda ------

    @Test
    void lambdaInvokeSendsASignedRequestAndDecodesTheLogTail() throws Exception {
        var result = lambdaRunner.run(command("awslambda",
                "order-fn\n{\"orderId\":42}", awsRaw(), awsCredentials()));
        assertTrue(result.success(), () -> "error: " + result.error());
        assertTrue(result.output().contains("{\"ok\":true}"));
        assertTrue(result.output().contains("START RequestId"));
        String auth = lastHeaders.get().getFirst("Authorization");
        assertNotNull(auth);
        assertTrue(auth.startsWith("AWS4-HMAC-SHA256 Credential=AKIATEST/"));
        assertEquals("RequestResponse",
                lastHeaders.get().getFirst("X-amz-invocation-type"));
    }

    @Test
    void lambdaFunctionErrorFailsTheStep() throws Exception {
        var result = lambdaRunner.run(command("awslambda", "broken-fn", awsRaw(),
                awsCredentials()));
        assertFalse(result.success());
        assertTrue(result.error().contains("Unhandled"));
        assertTrue(result.output().contains("errorMessage"));
    }

    @Test
    void lambdaWithoutRegionAnywhereFailsClearly() throws Exception {
        var credentials = MAPPER.readTree(
                "{\"platform\":\"AWS\",\"connection\":\"aws-prod\","
                        + "\"data\":{\"accessId\":\"AKIATEST\",\"secret\":\"s\"}}");
        var result = lambdaRunner.run(command("awslambda", "my-fn", null, credentials));
        assertFalse(result.success());
        assertTrue(result.error().contains("region"));
    }

    @Test
    void lambdaRegionIsParsedFromAFullArn() throws Exception {
        var credentials = MAPPER.readTree(
                "{\"platform\":\"AWS\",\"connection\":\"aws-prod\","
                        + "\"data\":{\"accessId\":\"AKIATEST\",\"secret\":\"s\"}}");
        // No endpoint override → the runner would target real AWS; the point
        // here is only that ARN parsing gets past the region check, so a
        // connect failure (or DNS error) proves region resolution worked.
        var result = lambdaRunner.run(command("awslambda",
                "arn:aws:lambda:eu-central-1:123456789012:function:my-fn", null, credentials));
        if (!result.success()) {
            assertFalse(result.error() != null && result.error().contains("No AWS region"));
        }
    }

    @Test
    void lambdaRejectsUnknownInvocationTypes() throws Exception {
        var raw = MAPPER.readTree("{\"endpoint\":\"" + base
                + "\",\"region\":\"eu-west-1\",\"invocationType\":\"Sideways\"}");
        var result = lambdaRunner.run(command("awslambda", "order-fn", raw, awsCredentials()));
        assertFalse(result.success());
        assertTrue(result.error().contains("invocationType"));
    }

    // ------ azurefn ------

    @Test
    void azureFunctionPostsBodyWithTheFunctionKey() throws Exception {
        var credentials = MAPPER.readTree(
                "{\"platform\":\"AZURE\",\"connection\":\"az-prod\","
                        + "\"data\":{\"functionKey\":\"k3y\"}}");
        var result = azureRunner.run(command("azurefn",
                base + "/api/ProcessOrder\n{\"orderId\":42}", null, credentials));
        assertTrue(result.success(), () -> "error: " + result.error());
        assertTrue(result.output().contains("processed"));
        assertEquals("k3y", lastHeaders.get().getFirst("X-functions-key"));
    }

    @Test
    void azureFunctionWorksAnonymouslyWithoutCredentials() throws Exception {
        var result = azureRunner.run(command("azurefn", base + "/api/ProcessOrder", null, null));
        assertTrue(result.success(), () -> "error: " + result.error());
    }

    @Test
    void azureFunctionAuthFailureNamesTheKeyProblem() throws Exception {
        var result = azureRunner.run(command("azurefn", base + "/api/Locked", null, null));
        assertFalse(result.success());
        assertTrue(result.error().contains("functionKey"));
    }

    @Test
    void azureFunctionSecretCodeNeverLandsInTheLog() throws Exception {
        var result = azureRunner.run(command("azurefn",
                base + "/api/ProcessOrder?code=SUPERSECRET", null, null));
        assertTrue(result.success());
        assertFalse(result.output().contains("SUPERSECRET"));
    }

    @Test
    void azureFunctionRejectsNonHttpUrls() throws Exception {
        var result = azureRunner.run(command("azurefn", "ftp://nope", null, null));
        assertFalse(result.success());
        assertTrue(result.error().contains("http"));
    }

    // ------------------------------------------------------------------

    private static com.fasterxml.jackson.databind.JsonNode awsRaw() throws Exception {
        return MAPPER.readTree("{\"endpoint\":\"" + base + "\",\"region\":\"eu-west-1\"}");
    }

    private static com.fasterxml.jackson.databind.JsonNode awsCredentials() throws Exception {
        return MAPPER.readTree("{\"platform\":\"AWS\",\"connection\":\"aws-prod\","
                + "\"data\":{\"accessId\":\"AKIATEST\",\"secret\":\"s3cr3t\"}}");
    }

    private static StepRunner.StepCommand command(String type, String value,
                                                  com.fasterxml.jackson.databind.JsonNode raw,
                                                  com.fasterxml.jackson.databind.JsonNode credentials) {
        return new StepRunner.StepCommand("tenant-a", type, "cloud step", value, raw,
                Duration.ofSeconds(15), credentials);
    }

    private static void respond(HttpExchange exchange, int status, String body)
            throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }
}