package com.intertec.autoops.jobs.service;

import com.intertec.autoops.jobs.config.JobProperties;
import com.intertec.autoops.jobs.execution.ProcessSupport;
import com.intertec.autoops.jobs.execution.StepRunner;
import com.intertec.autoops.jobs.execution.command.CommandRunner;
import com.intertec.autoops.jobs.execution.kubernetes.KubernetesRunner;
import com.intertec.autoops.jobs.execution.python.PythonRunner;
import com.intertec.autoops.jobs.execution.rest.RestRunner;
import com.intertec.autoops.jobs.execution.script.ScriptRunner;
import com.intertec.autoops.jobs.execution.ssh.SshRunner;
import com.intertec.autoops.jobs.execution.terraform.TerraformRunner;
import com.intertec.autoops.jobs.execution.test.TestRunner;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;

import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Real process execution, OS-aware (bash/sh in CI containers, cmd.exe on a
 * Windows dev box) — no Spring context needed.
 */
class StepExecutionServiceTest {

    private static StepExecutionService service;
    private static HttpServer httpServer;
    private static String httpBase;

    @BeforeAll
    static void setUp() throws Exception {
        JobProperties properties = new JobProperties();
        properties.setDefaultStepTimeout(Duration.ofSeconds(20));
        // CI runs the suite inside a root container with no step-user pool;
        // production refuses to run steps there, tests need them to run.
        properties.getSandbox().setAllowRootSteps(true);
        List<StepRunner> runners = List.of(
                new CommandRunner(properties), new ScriptRunner(properties),
                new PythonRunner(properties), new SshRunner(properties),
                new RestRunner(properties), new TestRunner(),
                new TerraformRunner(properties), new KubernetesRunner(properties),
                new com.intertec.autoops.jobs.execution.aws.AwsLambdaRunner(properties),
                new com.intertec.autoops.jobs.execution.azure.AzureFunctionRunner(properties));
        service = new StepExecutionService(runners, properties,
                new com.intertec.autoops.jobs.sandbox.StepSandbox(properties), emptyProvider());

        httpServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        httpServer.createContext("/ping", exchange -> respond(exchange, 200, "{\"pong\":true}"));
        httpServer.createContext("/boom", exchange -> respond(exchange, 500, "kaboom"));
        httpServer.start();
        httpBase = "http://127.0.0.1:" + httpServer.getAddress().getPort();
    }

    @AfterAll
    static void tearDown() {
        httpServer.stop(0);
    }

    // ------ command ------

    @Test
    void commandStepRunsAndCapturesOutput() {
        var execution = execute("command", "echo autoops-was-here");
        assertTrue(execution.success(), () -> "error: " + execution.error());
        assertTrue(execution.output().contains("autoops-was-here"));
        assertEquals(0, execution.exitCode());
    }

    @Test
    void failingCommandFailsWithExitCode() {
        var execution = execute("command", ProcessSupport.isWindows() ? "exit /b 3" : "exit 3");
        assertFalse(execution.success());
        assertEquals(3, execution.exitCode());
        assertTrue(execution.error().contains("code 3"));
    }

    @Test
    void agentTypeIsAnAliasForCommand() {
        var execution = execute("agent", "echo agent-alias-ok");
        assertTrue(execution.success());
        assertTrue(execution.output().contains("agent-alias-ok"));
    }

    @Test
    void blankCommandIsAConfigError() {
        var execution = execute("command", "   ");
        assertFalse(execution.success());
        assertTrue(execution.error().contains("no command"));
    }

    // ------ script ------

    @Test
    void multiLineScriptRuns() {
        String script = ProcessSupport.isWindows()
                ? "@echo off\r\necho line-one\r\necho line-two"
                : "echo line-one\necho line-two";
        var execution = execute("script", script);
        assertTrue(execution.success(), () -> "error: " + execution.error());
        assertTrue(execution.output().contains("line-one"));
        assertTrue(execution.output().contains("line-two"));
    }

    // ------ timeout ------

    @Test
    void runawayCommandIsKilledAtTheTimeout() {
        // Portable "sleep 10": ping loops locally on Windows, sleep elsewhere.
        String slow = ProcessSupport.isWindows()
                ? "ping -n 11 127.0.0.1 >nul" : "sleep 10";
        var execution = service.execute(new StepRunner.StepCommand(
                "tenant-a", "command", "slow step", slow, null, Duration.ofSeconds(1), null));
        assertFalse(execution.success());
        assertTrue(execution.error().contains("timed out"));
    }

    // ------ rest ------

    @Test
    void restStepCallsTheEndpoint() {
        var execution = execute("rest", httpBase + "/ping");
        assertTrue(execution.success(), () -> "error: " + execution.error());
        assertTrue(execution.output().contains("HTTP 200"));
        assertTrue(execution.output().contains("pong"));
    }

    @Test
    void restStepFailsOnServerError() {
        var execution = execute("rest", "GET " + httpBase + "/boom");
        assertFalse(execution.success());
        assertTrue(execution.error().contains("500"));
    }

    // ------ ssh ------

    @Test
    void sshStepRejectsMalformedTarget() {
        var execution = execute("ssh", "just-a-command-no-target");
        assertFalse(execution.success());
        assertTrue(execution.error().contains("user@host"));
    }

    // ------ dispatch ------

    @Test
    void testStepAlwaysSucceeds() {
        var execution = execute("test", null);
        assertTrue(execution.success());
    }

    @Test
    void unsupportedTypesFailHonestly() {
        var execution = execute("warpdrive", "engage");
        assertFalse(execution.success());
        assertTrue(execution.error().contains("No executor for step type 'warpdrive'"));
        assertEquals("none", execution.executor());
    }

    @Test
    void lambdaStepWithoutCredentialsFailsClearly() {
        var execution = execute("awslambda", "my-function");
        assertFalse(execution.success());
        assertTrue(execution.error().contains("AWS cloud integration"));
    }

    // ------ terraform / kubernetes (config paths; binaries live in the container) ------

    @Test
    void terraformStepRequiresConfiguration() {
        var execution = execute("terraform", "  ");
        assertFalse(execution.success());
        assertTrue(execution.error().contains("no configuration"));
    }

    @Test
    void terraformRejectsUnknownActions() throws Exception {
        var mapper = new com.fasterxml.jackson.databind.ObjectMapper();
        var raw = mapper.readTree("{\"action\":\"panic\"}");
        var execution = service.execute(new StepRunner.StepCommand(
                "tenant-a", "terraform", "tf", "output \"x\" {}", raw, null, null));
        assertFalse(execution.success());
        assertTrue(execution.error().contains("Unknown terraform action"));
    }

    @Test
    void terraformCredentialEnvMapsAllPlatforms() throws Exception {
        var mapper = new com.fasterxml.jackson.databind.ObjectMapper();
        var aws = TerraformRunner.credentialEnv(mapper.readTree(
                "{\"platform\":\"AWS\",\"data\":{\"accessId\":\"AKIA\",\"secret\":\"s3cr3t\",\"region\":\"eu-central-1\"}}"),
                java.nio.file.Files.createTempDirectory("tf-test"));
        assertEquals("AKIA", aws.get("AWS_ACCESS_KEY_ID"));
        assertEquals("s3cr3t", aws.get("AWS_SECRET_ACCESS_KEY"));
        assertEquals("eu-central-1", aws.get("AWS_DEFAULT_REGION"));

        var azure = TerraformRunner.credentialEnv(mapper.readTree(
                "{\"platform\":\"AZURE\",\"data\":{\"clientId\":\"c\",\"clientSecret\":\"x\",\"tenantId\":\"t\",\"subscriptionId\":\"s\"}}"),
                java.nio.file.Files.createTempDirectory("tf-test"));
        assertEquals("c", azure.get("ARM_CLIENT_ID"));
        assertEquals("s", azure.get("ARM_SUBSCRIPTION_ID"));

        var workDir = java.nio.file.Files.createTempDirectory("tf-test");
        var gcp = TerraformRunner.credentialEnv(mapper.readTree(
                "{\"platform\":\"GCP\",\"data\":{\"projectId\":\"p1\",\"serviceAccount\":\"{}\"}}"),
                workDir);
        assertEquals("p1", gcp.get("GOOGLE_PROJECT"));
        assertTrue(java.nio.file.Files.exists(
                java.nio.file.Path.of(gcp.get("GOOGLE_APPLICATION_CREDENTIALS"))));
    }

    @Test
    void kubernetesStepRequiresAKubeconfig() {
        var execution = execute("kubernetes", "get pods -A");
        assertFalse(execution.success());
        assertTrue(execution.error().contains("kubeconfig"));
    }

    @Test
    void executionIsTimed() {
        var execution = execute("command", "echo timed");
        assertNotNull(execution.output());
        assertTrue(execution.durationMs() >= 0);
    }

    // ------------------------------------------------------------------

    private static StepExecutionService.Execution execute(String type, String value) {
        return service.execute(new StepRunner.StepCommand(
                "tenant-a", type, "step under test", value, null, null, null));
    }

    private static void respond(com.sun.net.httpserver.HttpExchange exchange, int status,
                                String body) throws java.io.IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }

    private static ObjectProvider<io.micrometer.core.instrument.MeterRegistry> emptyProvider() {
        return new ObjectProvider<>() {
            @Override
            public io.micrometer.core.instrument.MeterRegistry getIfAvailable() {
                return null;
            }
            @Override
            public io.micrometer.core.instrument.MeterRegistry getObject() {
                throw new UnsupportedOperationException();
            }
        };
    }
}
