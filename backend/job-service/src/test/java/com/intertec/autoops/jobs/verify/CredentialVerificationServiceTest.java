package com.intertec.autoops.jobs.verify;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.micrometer.core.instrument.MeterRegistry;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.util.Base64;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Live-check logic against a local JDK HttpServer standing in for the
 * provider (the service honors an {@code endpoint} override in the stored
 * credential data — the same hook GovCloud/sovereign-cloud users need).
 */
class CredentialVerificationServiceTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private static CredentialVerificationService service;
    private static HttpServer server;
    private static String base;

    @BeforeAll
    static void setUp() throws Exception {
        com.intertec.autoops.jobs.config.JobProperties properties =
                new com.intertec.autoops.jobs.config.JobProperties();
        // The suite must also run inside a root CI container — see StepSandboxTest.
        properties.getSandbox().setAllowRootSteps(true);
        service = new CredentialVerificationService(MAPPER,
                new com.intertec.autoops.jobs.sandbox.StepSandbox(properties), emptyProvider());
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/sts-ok", exchange -> respond(exchange, 200,
                "<GetCallerIdentityResponse><Account>123456789012</Account>"
                        + "<Arn>arn:aws:iam::123456789012:user/autoops</Arn>"
                        + "</GetCallerIdentityResponse>"));
        server.createContext("/arm-sub", exchange -> respond(exchange, 200,
                "{\"subscriptionId\":\"sub-guid\",\"displayName\":\"Contoso Production\","
                        + "\"state\":\"Enabled\",\"tenantId\":\"tenant-from-arm\"}"));
        server.createContext("/arm-denied", exchange -> respond(exchange, 403,
                "{\"error\":{\"code\":\"AuthorizationFailed\"}}"));
        server.createContext("/arm-missing", exchange -> respond(exchange, 404,
                "{\"error\":{\"code\":\"SubscriptionNotFound\"}}"));
        server.createContext("/arm-list", exchange -> respond(exchange, 200,
                "{\"value\":[{\"subscriptionId\":\"other-guid\","
                        + "\"displayName\":\"Contoso Dev\"}]}"));
        server.createContext("/arm-list-empty", exchange -> respond(exchange, 200,
                "{\"value\":[]}"));
        server.createContext("/arm-list-has-it", exchange -> respond(exchange, 200,
                "{\"value\":[{\"subscriptionId\":\"sub-guid\","
                        + "\"displayName\":\"Contoso Production\"}]}"));
        server.createContext("/graph-org", exchange -> respond(exchange, 200,
                "{\"value\":[{\"id\":\"tenant-guid\",\"displayName\":\"Contoso Ltd\"}]}"));
        server.createContext("/crm-project", exchange -> respond(exchange, 200,
                "{\"projectId\":\"my-proj\",\"name\":\"My Project\"}"));
        server.createContext("/sts-bad", exchange -> respond(exchange, 403,
                "<ErrorResponse><Error><Code>InvalidClientTokenId</Code>"
                        + "<Message>The security token included in the request is invalid."
                        + "</Message></Error></ErrorResponse>"));
        server.createContext("/aad-ok", exchange -> respond(exchange, 200,
                "{\"access_token\":\"t\",\"token_type\":\"Bearer\"}"));
        server.createContext("/aad-bad", exchange -> respond(exchange, 401,
                "{\"error\":\"invalid_client\",\"error_description\":"
                        + "\"AADSTS7000215: Invalid client secret provided.\\nTrace ID: x\"}"));
        server.createContext("/gcp-token", exchange -> respond(exchange, 200,
                "{\"access_token\":\"ya29.x\",\"expires_in\":3600}"));
        server.start();
        base = "http://127.0.0.1:" + server.getAddress().getPort();
    }

    @AfterAll
    static void tearDown() {
        server.stop(0);
    }

    // ------ AWS ------

    @Test
    void awsAcceptedCredentialsReportTheCallerArn() throws Exception {
        var result = service.verify("t1", "AWS", data(
                "{\"accessId\":\"AKIA\",\"secret\":\"s\",\"endpoint\":\"" + base + "/sts-ok\"}"));
        assertTrue(result.supported());
        assertTrue(result.verified());
        assertTrue(result.message().contains("arn:aws:iam::123456789012:user/autoops"));
        assertEquals("123456789012", result.accountId(), "the real AWS account number");
        assertEquals("autoops", result.accountName(), "the IAM identity from the ARN");
    }

    @Test
    void azureReportsTheSubscriptionIdAndItsDisplayName() throws Exception {
        var result = service.verify("t1", "AZURE", data(
                "{\"clientId\":\"c\",\"clientSecret\":\"s\",\"tenantId\":\"t\","
                        + "\"subscriptionId\":\"sub-guid\","
                        + "\"endpoint\":\"" + base + "/aad-ok\","
                        + "\"resourceEndpoint\":\"" + base + "/arm-sub\"}"));
        assertTrue(result.verified());
        assertEquals("sub-guid", result.accountId());
        assertEquals("Contoso Production", result.accountName());
        assertTrue(result.message().contains("Contoso Production"));
        assertEquals(java.util.List.of("Subscription name", "Subscription ID"),
                java.util.List.copyOf(result.details().keySet()),
                "Azure shows only the subscription's name and id");
        assertEquals("Contoso Production", result.details().get("Subscription name"));
        assertEquals("sub-guid", result.details().get("Subscription ID"));
    }

    @Test
    void azureSaysWhyTheSubscriptionNameIsMissingRatherThanHidingIt() throws Exception {
        var result = service.verify("t1", "AZURE", data(
                "{\"clientId\":\"c\",\"clientSecret\":\"s\",\"tenantId\":\"t\","
                        + "\"subscriptionId\":\"sub-guid\","
                        + "\"endpoint\":\"" + base + "/aad-ok\","
                        + "\"resourceEndpoint\":\"" + base + "/arm-denied\"}"));
        assertTrue(result.verified(), "a missing role must not fail the verification");
        assertEquals("No access", result.details().get("Subscription name"),
                "the row stays short — guidance belongs in the message");
        assertTrue(result.message().contains("Reader"), result.message());
        assertEquals("sub-guid", result.details().get("Subscription ID"));
    }

    @Test
    void azureNamesTheSubscriptionsTheAppCanActuallySee() throws Exception {
        var result = service.verify("t1", "AZURE", data(
                "{\"clientId\":\"c\",\"clientSecret\":\"s\",\"tenantId\":\"t\","
                        + "\"subscriptionId\":\"sub-guid\","
                        + "\"endpoint\":\"" + base + "/aad-ok\","
                        + "\"resourceEndpoint\":\"" + base + "/arm-missing\","
                        + "\"resourceListEndpoint\":\"" + base + "/arm-list\"}"));
        assertEquals("No access", result.details().get("Subscription name"),
                "the name row is never a paragraph");
        assertTrue(result.message().contains("Contoso Dev (other-guid)"),
                "a wrong id is diagnosed in the message by naming what the app CAN reach: "
                        + result.message());
    }

    @Test
    void azureSaysNoRoleAnywhereWhenTheAppSeesNoSubscriptions() throws Exception {
        var result = service.verify("t1", "AZURE", data(
                "{\"clientId\":\"c\",\"clientSecret\":\"s\",\"tenantId\":\"t\","
                        + "\"subscriptionId\":\"sub-guid\","
                        + "\"endpoint\":\"" + base + "/aad-ok\","
                        + "\"resourceEndpoint\":\"" + base + "/arm-missing\","
                        + "\"resourceListEndpoint\":\"" + base + "/arm-list-empty\"}"));
        assertEquals("No access", result.details().get("Subscription name"));
        assertTrue(result.message().contains("no role on any"), result.message());
    }

    @Test
    void azureRecoversTheNameFromTheListWhenTheDirectLookupFails() throws Exception {
        var result = service.verify("t1", "AZURE", data(
                "{\"clientId\":\"c\",\"clientSecret\":\"s\",\"tenantId\":\"t\","
                        + "\"subscriptionId\":\"sub-guid\","
                        + "\"endpoint\":\"" + base + "/aad-ok\","
                        + "\"resourceEndpoint\":\"" + base + "/arm-missing\","
                        + "\"resourceListEndpoint\":\"" + base + "/arm-list-has-it\"}"));
        assertEquals("Contoso Production", result.details().get("Subscription name"),
                "the list can answer what the direct GET would not");
    }

    @Test
    void pastedCredentialValuesAreTrimmed() throws Exception {
        // A trailing newline on a pasted subscription id used to be spliced
        // straight into the ARM URL, producing an inexplicable 404.
        var result = service.verify("t1", "AZURE", data(
                "{\"clientId\":\"c\",\"clientSecret\":\"s\",\"tenantId\":\"t\","
                        + "\"subscriptionId\":\"  sub-guid\\n\","
                        + "\"endpoint\":\"" + base + "/aad-ok\","
                        + "\"resourceEndpoint\":\"" + base + "/arm-sub\"}"));
        assertEquals("sub-guid", result.accountId());
        assertEquals("sub-guid", result.details().get("Subscription ID"));
    }

    /**
     * ARM answers 404 — not 403 — for a subscription the caller has no role
     * on, so a bare "HTTP 404" would read as a bug rather than a permission
     * to grant.
     */
    @Test
    void azureTreatsArmNotFoundAsAPermissionHintNotARawStatus() throws Exception {
        var result = service.verify("t1", "AZURE", data(
                "{\"clientId\":\"c\",\"clientSecret\":\"s\",\"tenantId\":\"t\","
                        + "\"subscriptionId\":\"sub-guid\","
                        + "\"endpoint\":\"" + base + "/aad-ok\","
                        + "\"resourceEndpoint\":\"" + base + "/arm-missing\"}"));
        assertTrue(result.verified());
        String detail = result.details().get("Subscription name");
        assertEquals("No access", detail);
        assertFalse(result.message().contains("404"),
                "raw status codes are not actionable: " + result.message());
    }

    @Test
    void azureStaysVerifiedWhenTheNameLookupIsNotPermitted() throws Exception {
        // No resourceEndpoint + a stubbed token endpoint: the ARM lookup is
        // skipped entirely, and that must not change the verdict.
        var result = service.verify("t1", "AZURE", data(
                "{\"clientId\":\"c\",\"clientSecret\":\"s\",\"tenantId\":\"t\","
                        + "\"subscriptionId\":\"sub-guid\",\"endpoint\":\"" + base + "/aad-ok\"}"));
        assertTrue(result.verified());
        assertEquals("sub-guid", result.accountId());
        assertEquals(null, result.accountName());
    }

    @Test
    void m365VerifiesThroughEntraAndNamesTheOrganization() throws Exception {
        var result = service.verify("t1", "M365", data(
                "{\"clientId\":\"c\",\"clientSecret\":\"s\",\"tenantId\":\"tenant-guid\","
                        + "\"endpoint\":\"" + base + "/aad-ok\","
                        + "\"resourceEndpoint\":\"" + base + "/graph-org\"}"));
        assertTrue(result.supported(), "M365 is a real live check now, not unsupported");
        assertTrue(result.verified());
        assertEquals("tenant-guid", result.accountId());
        assertEquals("Contoso Ltd", result.accountName());
    }

    @Test
    void m365RejectionSurfacesTheAadstsCode() throws Exception {
        var result = service.verify("t1", "M365", data(
                "{\"clientId\":\"c\",\"clientSecret\":\"bad\",\"tenantId\":\"t\","
                        + "\"endpoint\":\"" + base + "/aad-bad\"}"));
        assertTrue(result.supported());
        assertFalse(result.verified());
        assertTrue(result.message().contains("AADSTS7000215"));
    }

    @Test
    void awsRejectionSurfacesTheStsMessage() throws Exception {
        var result = service.verify("t1", "AWS", data(
                "{\"accessId\":\"AKIA\",\"secret\":\"bad\",\"endpoint\":\"" + base + "/sts-bad\"}"));
        assertTrue(result.supported());
        assertFalse(result.verified());
        assertTrue(result.message().contains("security token included in the request is invalid"));
    }

    /**
     * Regression: signing for eu-central-1 and posting to the GLOBAL
     * sts.amazonaws.com made AWS answer 403 "Credential should be scoped to
     * a valid region" for every connection outside us-east-1.
     */
    @Test
    void stsEndpointIsTheRegionsOwnNotTheGlobalOne() {
        assertTrue(CredentialVerificationService.stsEndpoint("eu-central-1")
                .equals("https://sts.eu-central-1.amazonaws.com/"));
        assertTrue(CredentialVerificationService.stsEndpoint("us-east-1")
                .equals("https://sts.us-east-1.amazonaws.com/"));
        // Opt-in regions exist ONLY as regional endpoints.
        assertTrue(CredentialVerificationService.stsEndpoint("me-south-1")
                .equals("https://sts.me-south-1.amazonaws.com/"));
        // The China partition is a different top-level domain.
        assertTrue(CredentialVerificationService.stsEndpoint("cn-north-1")
                .equals("https://sts.cn-north-1.amazonaws.com.cn/"));
    }

    @Test
    void awsGarbageRegionFailsBeforeAnyNetworkCall() throws Exception {
        var result = service.verify("t1", "AWS", data(
                "{\"accessId\":\"AKIA\",\"secret\":\"s\",\"region\":\"evil.example.com\"}"));
        assertTrue(result.supported());
        assertFalse(result.verified());
        assertTrue(result.message().contains("not a valid AWS region"),
                "a malformed region must never be pasted into the endpoint host");
    }

    @Test
    void awsMissingKeysFailBeforeAnyNetworkCall() throws Exception {
        var result = service.verify("t1", "AWS", data("{\"region\":\"eu-west-1\"}"));
        assertFalse(result.verified());
        assertTrue(result.message().contains("Missing access key"));
    }

    // ------ AZURE ------

    @Test
    void azureAcceptedServicePrincipalVerifies() throws Exception {
        var result = service.verify("t1", "AZURE", data(
                "{\"clientId\":\"c\",\"clientSecret\":\"s\",\"tenantId\":\"t\","
                        + "\"endpoint\":\"" + base + "/aad-ok\"}"));
        assertTrue(result.verified());
        assertTrue(result.message().contains("Entra ID"));
    }

    @Test
    void azureRejectionSurfacesTheAadstsCodeFirstLineOnly() throws Exception {
        var result = service.verify("t1", "AZURE", data(
                "{\"clientId\":\"c\",\"clientSecret\":\"bad\",\"tenantId\":\"t\","
                        + "\"endpoint\":\"" + base + "/aad-bad\"}"));
        assertFalse(result.verified());
        assertTrue(result.message().contains("AADSTS7000215"));
        assertFalse(result.message().contains("Trace ID"));
    }

    // ------ GCP ------

    @Test
    void gcpServiceAccountSignsAJwtAndVerifies() throws Exception {
        KeyPair keyPair = KeyPairGenerator.getInstance("RSA").generateKeyPair();
        String pem = "-----BEGIN PRIVATE KEY-----\n"
                + Base64.getMimeEncoder(64, "\n".getBytes())
                        .encodeToString(keyPair.getPrivate().getEncoded())
                + "\n-----END PRIVATE KEY-----\n";
        String serviceAccount = MAPPER.writeValueAsString(java.util.Map.of(
                "client_email", "svc@proj.iam.gserviceaccount.com",
                "private_key", pem,
                "token_uri", base + "/gcp-token"));
        var result = service.verify("t1", "GCP", data(MAPPER.writeValueAsString(
                java.util.Map.of("serviceAccount", serviceAccount,
                        "projectId", "my-proj",
                        "resourceEndpoint", base + "/crm-project"))));
        assertTrue(result.verified(), () -> result.message());
        assertTrue(result.message().contains("svc@proj.iam.gserviceaccount.com"));
        assertEquals("my-proj", result.accountId());
        assertEquals("My Project", result.accountName());
    }

    @Test
    void gcpGarbagePrivateKeyFailsWithoutCrashing() throws Exception {
        String serviceAccount = MAPPER.writeValueAsString(java.util.Map.of(
                "client_email", "svc@proj.iam.gserviceaccount.com",
                "private_key", "-----BEGIN PRIVATE KEY-----\nnot-a-key\n-----END PRIVATE KEY-----",
                "token_uri", base + "/gcp-token"));
        var result = service.verify("t1", "GCP", data(MAPPER.writeValueAsString(
                java.util.Map.of("serviceAccount", serviceAccount))));
        assertFalse(result.verified());
        assertTrue(result.message().contains("private_key"));
    }

    // ------ dispatch ------

    @Test
    void platformsWithoutALiveCheckAreHonestlyUnsupported() throws Exception {
        var result = service.verify("t1", "HUAWEI", data("{}"));
        assertFalse(result.supported());
        assertFalse(result.verified());
        assertTrue(result.message().contains("HUAWEI"));
    }

    @Test
    void kubernetesWithoutAKubeconfigFailsClearly() throws Exception {
        var result = service.verify("t1", "KUBERNETES", data("{}"));
        assertTrue(result.supported());
        assertFalse(result.verified());
        assertTrue(result.message().contains("kubeconfig"));
    }

    // ------------------------------------------------------------------

    private static JsonNode data(String json) throws Exception {
        return MAPPER.readTree(json);
    }

    private static void respond(HttpExchange exchange, int status, String body)
            throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }

    private static ObjectProvider<MeterRegistry> emptyProvider() {
        return new ObjectProvider<>() {
            @Override
            public MeterRegistry getIfAvailable() {
                return null;
            }

            @Override
            public MeterRegistry getObject() {
                throw new UnsupportedOperationException();
            }
        };
    }
}
