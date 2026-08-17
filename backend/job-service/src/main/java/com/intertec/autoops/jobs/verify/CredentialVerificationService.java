package com.intertec.autoops.jobs.verify;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.jobs.execution.ProcessSupport;
import com.intertec.autoops.jobs.execution.aws.AwsV4;
import com.intertec.autoops.jobs.sandbox.SandboxException;
import com.intertec.autoops.jobs.sandbox.StepSandbox;
import com.intertec.autoops.jobs.sandbox.StepWorkspace;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.spec.PKCS8EncodedKeySpec;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Verifies stored cloud-integration credentials against the REAL platform
 * API — the cheapest read-only "who am I" call each provider offers:
 * AWS → STS GetCallerIdentity, AZURE → Entra ID client-credentials token,
 * GCP → service-account OAuth token grant, KUBERNETES → the cluster's
 * /version endpoint via kubectl. Nothing is mutated on the provider side.
 * Platforms without a live check yet report {@code supported=false} honestly
 * instead of pretending.
 */
@Service
public class CredentialVerificationService {

    private static final Logger log = LoggerFactory.getLogger(CredentialVerificationService.class);
    private static final Duration TIMEOUT = Duration.ofSeconds(15);
    private static final Pattern STS_ARN = Pattern.compile("<Arn>([^<]+)</Arn>");
    private static final Pattern STS_ACCOUNT = Pattern.compile("<Account>(\\d+)</Account>");
    private static final Pattern STS_USER_ID = Pattern.compile("<UserId>([^<]+)</UserId>");
    /** The cluster nickname a kubeconfig is currently pointed at. */
    private static final Pattern KUBE_CONTEXT = Pattern.compile("current-context:\\s*(\\S+)");
    private static final Pattern KUBE_SERVER = Pattern.compile("server:\\s*(\\S+)");
    private static final Pattern XML_MESSAGE = Pattern.compile("<Message>([^<]+)</Message>");
    /** Region codes: us-east-1, ap-southeast-3, us-gov-west-1, cn-north-1. */
    private static final Pattern AWS_REGION = Pattern.compile("^[a-z]{2}(-[a-z]+)+-\\d+$");

    private final ObjectMapper objectMapper;
    private final StepSandbox sandbox;
    /** Nullable: tests have no MeterRegistry; prod wires Prometheus. */
    private final MeterRegistry meterRegistry;

    public CredentialVerificationService(ObjectMapper objectMapper, StepSandbox sandbox,
                                         ObjectProvider<MeterRegistry> meterRegistry) {
        this.objectMapper = objectMapper;
        this.sandbox = sandbox;
        this.meterRegistry = meterRegistry.getIfAvailable();
    }

    /**
     * @param accountId   the provider's own identifier for the account
     *                    (AWS account number, Azure subscription id, GCP
     *                    project, Entra tenant, cluster URL) — null when the
     *                    provider did not tell us
     * @param accountName the human-readable name of that account, when the
     *                    provider exposes one to these credentials
     */
    public record Verification(boolean supported, boolean verified, String message,
                               String accountId, String accountName,
                               Map<String, String> details) {

        static Verification ok(String message) {
            return new Verification(true, true, message, null, null, Map.of());
        }

        static Verification failed(String message) {
            return new Verification(true, false, message, null, null, Map.of());
        }

        static Verification unsupported(String platform) {
            return new Verification(false, false,
                    "No live verification for " + platform + " yet — credentials are stored "
                            + "but have not been checked against the provider",
                    null, null, Map.of());
        }

        Verification withAccount(String id, String name) {
            return new Verification(supported, verified, message, id, name, details);
        }

        /** Provider-reported facts shown beside the verdict, in this order. */
        Verification withDetails(Map<String, String> extra) {
            return new Verification(supported, verified, message, accountId, accountName, extra);
        }
    }

    /** Ordered, null-and-blank-skipping detail map for the UI. */
    private static Map<String, String> details(String... keyValuePairs) {
        Map<String, String> map = new LinkedHashMap<>();
        for (int i = 0; i + 1 < keyValuePairs.length; i += 2) {
            String value = keyValuePairs[i + 1];
            if (value != null && !value.isBlank()) {
                map.put(keyValuePairs[i], value);
            }
        }
        return map;
    }

    public Verification verify(String tenantId, String platform, JsonNode data) {
        String normalized = platform == null ? "" : platform.toUpperCase(Locale.ROOT);
        Verification verification;
        try {
            verification = switch (normalized) {
                case "AWS" -> verifyAws(data);
                case "AZURE" -> verifyAzure(data);
                case "GCP" -> verifyGcp(data);
                case "M365" -> verifyM365(data);
                case "KUBERNETES" -> verifyKubernetes(data);
                default -> Verification.unsupported(normalized.isEmpty() ? "?" : normalized);
            };
        } catch (Exception ex) {
            log.warn("Verification of {} credentials for tenant {} errored: {}",
                    normalized, tenantId, ex.getMessage());
            verification = Verification.failed("Verification call failed: " + ex.getMessage());
        }
        count(normalized, verification);
        log.info("Tenant {} verified {} credentials -> {}", tenantId, normalized,
                verification.verified() ? "ok" : "failed");
        return verification;
    }

    // ------ AWS: STS GetCallerIdentity ------

    private Verification verifyAws(JsonNode data) throws Exception {
        String accessKey = text(data, "accessId", "accessKey", "accessKeyId");
        String secretKey = text(data, "secret", "secretKey", "secretAccessKey");
        if (accessKey == null || secretKey == null) {
            return Verification.failed("Missing access key or secret in the stored credentials");
        }
        String endpoint = text(data, "endpoint");
        String region = text(data, "region");
        if (region != null && !AWS_REGION.matcher(region).matches()) {
            return Verification.failed("'" + region + "' is not a valid AWS region code");
        }
        String signingRegion = region != null ? region : "us-east-1";
        URI uri = URI.create(endpoint != null ? endpoint : stsEndpoint(signingRegion));
        byte[] body = "Action=GetCallerIdentity&Version=2011-06-15"
                .getBytes(StandardCharsets.UTF_8);
        Map<String, String> signed = AwsV4.headers("POST", uri, signingRegion, "sts",
                accessKey, secretKey, text(data, "sessionToken"), body, Instant.now());

        HttpRequest.Builder request = HttpRequest.newBuilder(uri)
                .timeout(TIMEOUT)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofByteArray(body));
        signed.forEach(request::header);
        HttpResponse<String> response = send(request.build());

        if (response.statusCode() == 200) {
            Matcher arn = STS_ARN.matcher(response.body());
            String callerArn = arn.find() ? arn.group(1) : null;
            Matcher account = STS_ACCOUNT.matcher(response.body());
            String accountNumber = account.find() ? account.group(1) : null;
            Matcher userId = STS_USER_ID.matcher(response.body());
            return Verification.ok("Authenticated with AWS"
                            + (callerArn != null ? " as " + callerArn : ""))
                    .withAccount(accountNumber, callerName(callerArn))
                    .withDetails(details(
                            "Identity", callerName(callerArn),
                            "Account", accountNumber,
                            "ARN", callerArn,
                            "User ID", userId.find() ? userId.group(1) : null,
                            "Region", signingRegion));
        }
        Matcher message = XML_MESSAGE.matcher(response.body());
        return Verification.failed("AWS rejected the credentials (HTTP " + response.statusCode()
                + (message.find() ? "): " + message.group(1) : ")"));
    }

    /** arn:aws:iam::123456789012:user/autoops -> "autoops" (the IAM identity). */
    private static String callerName(String arn) {
        if (arn == null) {
            return null;
        }
        int slash = arn.indexOf('/');
        String name = slash >= 0 ? arn.substring(slash + 1) : arn.substring(arn.lastIndexOf(':') + 1);
        return name.isBlank() ? null : name;
    }

    /**
     * The region's own STS endpoint. The global {@code sts.amazonaws.com}
     * only accepts signatures whose credential scope says us-east-1, and it
     * refuses opt-in regions (ap-east-1, af-south-1, me-south-1,
     * il-central-1, …) outright — signing for any other region and posting
     * there earns a 403 "Credential should be scoped to a valid region"
     * before AWS ever looks at the keys.
     */
    static String stsEndpoint(String region) {
        // The China partition lives on a different top-level domain.
        String suffix = region.startsWith("cn-") ? ".amazonaws.com.cn" : ".amazonaws.com";
        return "https://sts." + region + suffix + "/";
    }

    // ------ AZURE: Entra ID client-credentials grant ------

    private Verification verifyAzure(JsonNode data) throws Exception {
        String clientId = text(data, "clientId");
        String clientSecret = text(data, "clientSecret");
        String tenantId = text(data, "tenantId");
        if (clientId == null || clientSecret == null || tenantId == null) {
            return Verification.failed(
                    "Missing clientId, clientSecret, or tenantId in the stored credentials");
        }
        String endpoint = text(data, "endpoint");
        URI uri = URI.create(endpoint != null ? endpoint
                : "https://login.microsoftonline.com/" + tenantId + "/oauth2/v2.0/token");
        HttpResponse<String> response = send(HttpRequest.newBuilder(uri)
                .timeout(TIMEOUT)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(entraForm(clientId, clientSecret,
                        "https://management.azure.com/.default")))
                .build());

        if (response.statusCode() == 200) {
            String subscriptionId = text(data, "subscriptionId");
            String resourceEndpoint = text(data, "resourceEndpoint");
            Lookup subscription = subscriptionId != null && lookupAllowed(uri, resourceEndpoint,
                    "https://login.microsoftonline.com")
                    ? bearerGet(resourceEndpoint != null ? resourceEndpoint
                            : "https://management.azure.com/subscriptions/" + subscriptionId
                                    + "?api-version=2022-12-01",
                            jsonField(response.body(), "access_token"))
                    : null;
            String direct = subscription != null && subscription.ok()
                    ? jsonField(subscription.body(), "displayName") : null;
            NameOutcome name = direct != null ? NameOutcome.found(direct)
                    : subscription != null
                            ? azureName(subscription, subscriptionId,
                                    jsonField(response.body(), "access_token"),
                                    resourceEndpoint, text(data, "resourceListEndpoint"))
                            : NameOutcome.unknown();
            return Verification.ok("Service principal authenticated with Microsoft Entra ID"
                            + (name.name() != null ? " — subscription " + name.name() : "")
                            + (name.hint() != null ? ". " + name.hint() : ""))
                    .withAccount(subscriptionId != null ? subscriptionId : tenantId, name.name())
                    // Azure shows just the two facts that identify the account;
                    // anything longer belongs in the message, not in a row.
                    .withDetails(details(
                            "Subscription name", name.value(),
                            "Subscription ID", subscriptionId));
        }
        String detail = jsonField(response.body(), "error_description");
        if (detail != null) {
            detail = detail.split("\r?\n", 2)[0]; // first line: the AADSTS code + summary
        }
        return Verification.failed("Microsoft Entra ID rejected the credentials (HTTP "
                + response.statusCode() + (detail != null ? "): " + detail : ")"));
    }

    /**
     * The subscription name for the detail row, and separately the guidance
     * that explains a missing one.
     *
     * @param name  the real name, or null when the provider would not say
     * @param value the short text for the "Subscription name" row
     * @param hint  the longer explanation, shown with the verdict message
     */
    private record NameOutcome(String name, String value, String hint) {

        static NameOutcome found(String name) {
            return new NameOutcome(name, name, null);
        }

        static NameOutcome unavailable(String value, String hint) {
            return new NameOutcome(null, value, hint);
        }

        static NameOutcome unknown() {
            return new NameOutcome(null, null, null);
        }
    }

    /**
     * ARM answers 404 both for "no role assignment" and for "no such
     * subscription", which leaves the user guessing. Asking ARM which
     * subscriptions this app CAN see settles it: an empty list means no role
     * anywhere, and a non-empty one that omits the id they typed means the id
     * is wrong — and names the ones that would work.
     */
    private NameOutcome azureName(Lookup subscription, String subscriptionId,
                                  String accessToken, String resourceEndpoint,
                                  String resourceListEndpoint) {
        String remedy = "Grant this app a Reader role on the subscription, or check the "
                + "subscription ID.";
        boolean denied = subscription.status() == 401 || subscription.status() == 403
                || subscription.status() == 404;
        boolean canList = resourceListEndpoint != null
                || (resourceEndpoint == null && accessToken != null);
        if (!denied || !canList) {
            // Either an odd failure, or we cannot ask ARM what this app can
            // reach — say which of the two without inventing a diagnosis.
            return denied
                    ? NameOutcome.unavailable("No access", remedy)
                    : NameOutcome.unavailable("Unavailable",
                            "Subscription lookup failed (HTTP "
                                    + (subscription.status() == 0 ? "no response"
                                            : subscription.status()) + ").");
        }
        Lookup all = bearerGet(resourceListEndpoint != null ? resourceListEndpoint
                : "https://management.azure.com/subscriptions?api-version=2022-12-01",
                accessToken);
        if (!all.ok()) {
            return NameOutcome.unavailable("No access", remedy);
        }
        List<String> visible = new java.util.ArrayList<>();
        try {
            for (JsonNode node : objectMapper.readTree(all.body()).path("value")) {
                String id = asText(node, "subscriptionId");
                String displayName = asText(node, "displayName");
                // The direct GET can fail while the list still works; if the
                // subscription is in here, we already have the answer.
                if (id != null && id.equalsIgnoreCase(subscriptionId) && displayName != null) {
                    return NameOutcome.found(displayName);
                }
                visible.add(displayName != null ? displayName + " (" + id + ")" : id);
            }
        } catch (Exception ex) {
            return NameOutcome.unavailable("No access", remedy);
        }
        if (visible.isEmpty()) {
            return NameOutcome.unavailable("No access",
                    "This app has no role on any subscription in the tenant — grant it Reader "
                            + "under Subscription → Access control (IAM).");
        }
        String shown = String.join(", ", visible.subList(0, Math.min(3, visible.size())));
        return NameOutcome.unavailable("No access",
                "This app has no role on the subscription ID entered. It can access: "
                        + shown + (visible.size() > 3 ? ", …" : ""));
    }

    // ------ M365: Entra ID token + the tenant's own directory ------

    private Verification verifyM365(JsonNode data) throws Exception {
        String clientId = text(data, "clientId");
        String clientSecret = text(data, "clientSecret");
        String tenantId = text(data, "tenantId");
        if (clientId == null || clientSecret == null || tenantId == null) {
            return Verification.failed(
                    "Missing clientId, clientSecret, or tenantId in the stored credentials");
        }
        String endpoint = text(data, "endpoint");
        URI uri = URI.create(endpoint != null ? endpoint
                : "https://login.microsoftonline.com/" + tenantId + "/oauth2/v2.0/token");
        HttpResponse<String> response = send(HttpRequest.newBuilder(uri)
                .timeout(TIMEOUT)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(entraForm(clientId, clientSecret,
                        "https://graph.microsoft.com/.default")))
                .build());

        if (response.statusCode() == 200) {
            String resourceEndpoint = text(data, "resourceEndpoint");
            Lookup org = lookupAllowed(uri, resourceEndpoint,
                    "https://login.microsoftonline.com")
                    ? bearerGet(resourceEndpoint != null ? resourceEndpoint
                            : "https://graph.microsoft.com/v1.0/organization",
                            jsonField(response.body(), "access_token"))
                    : null;
            JsonNode organization = org != null && org.ok() ? firstOrganization(org.body()) : null;
            String orgName = organization != null ? asText(organization, "displayName") : null;
            return Verification.ok("Application authenticated with Microsoft 365"
                            + (orgName != null ? " — " + orgName : ""))
                    .withAccount(tenantId, orgName)
                    .withDetails(details(
                            "Organization", orgName != null ? orgName
                                    : org != null
                                            ? "Name " + org.problem(
                                                    "the Organization.Read.All permission")
                                            : null,
                            "Tenant ID", tenantId,
                            "Country", organization != null
                                    ? asText(organization, "countryLetterCode") : null,
                            "Client ID", clientId));
        }
        String detail = jsonField(response.body(), "error_description");
        if (detail != null) {
            detail = detail.split("\r?\n", 2)[0];
        }
        return Verification.failed("Microsoft 365 rejected the credentials (HTTP "
                + response.statusCode() + (detail != null ? "): " + detail : ")"));
    }

    /** Graph returns the tenant's organization as a single-element list. */
    private JsonNode firstOrganization(String body) {
        try {
            JsonNode first = objectMapper.readTree(body).path("value").path(0);
            return first.isObject() ? first : null;
        } catch (Exception ex) {
            return null;
        }
    }

    private static String asText(JsonNode node, String field) {
        JsonNode value = node.path(field);
        return value.isTextual() && !value.asText().isBlank() ? value.asText() : null;
    }

    private static String entraForm(String clientId, String clientSecret, String scope) {
        return "grant_type=client_credentials"
                + "&client_id=" + URLEncoder.encode(clientId, StandardCharsets.UTF_8)
                + "&client_secret=" + URLEncoder.encode(clientSecret, StandardCharsets.UTF_8)
                + "&scope=" + URLEncoder.encode(scope, StandardCharsets.UTF_8);
    }

    // ------ GCP: service-account OAuth token grant ------

    private Verification verifyGcp(JsonNode data) throws Exception {
        String serviceAccount = text(data, "serviceAccount", "serviceAccountJson");
        if (serviceAccount == null) {
            return Verification.failed(
                    "Missing serviceAccount JSON in the stored credentials");
        }
        JsonNode sa;
        try {
            sa = objectMapper.readTree(serviceAccount);
        } catch (Exception ex) {
            return Verification.failed("serviceAccount is not valid JSON");
        }
        String clientEmail = sa.path("client_email").asText(null);
        String privateKeyPem = sa.path("private_key").asText(null);
        if (clientEmail == null || privateKeyPem == null) {
            return Verification.failed(
                    "serviceAccount JSON is missing client_email or private_key");
        }
        String endpoint = text(data, "endpoint");
        String tokenUri = endpoint != null ? endpoint
                : sa.path("token_uri").asText("https://oauth2.googleapis.com/token");

        String assertion;
        try {
            assertion = signedJwt(clientEmail, privateKeyPem, tokenUri);
        } catch (Exception ex) {
            return Verification.failed("private_key is unreadable: " + ex.getMessage());
        }
        String form = "grant_type=" + URLEncoder.encode(
                "urn:ietf:params:oauth:grant-type:jwt-bearer", StandardCharsets.UTF_8)
                + "&assertion=" + URLEncoder.encode(assertion, StandardCharsets.UTF_8);
        HttpResponse<String> response = send(HttpRequest.newBuilder(URI.create(tokenUri))
                .timeout(TIMEOUT)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(form))
                .build());

        if (response.statusCode() == 200) {
            String projectId = text(data, "projectId");
            if (projectId == null) {
                projectId = sa.path("project_id").isTextual()
                        ? sa.path("project_id").asText() : null;
            }
            String resourceEndpoint = text(data, "resourceEndpoint");
            Lookup project = projectId != null && lookupAllowed(URI.create(tokenUri),
                    resourceEndpoint, "https://oauth2.googleapis.com")
                    ? bearerGet(resourceEndpoint != null ? resourceEndpoint
                            : "https://cloudresourcemanager.googleapis.com/v1/projects/"
                                    + projectId,
                            jsonField(response.body(), "access_token"))
                    : null;
            String name = project != null && project.ok()
                    ? jsonField(project.body(), "name") : null;
            return Verification.ok("Service account " + clientEmail
                            + " authenticated with Google Cloud"
                            + (name != null ? " — project " + name : ""))
                    .withAccount(projectId, name != null ? name : clientEmail)
                    .withDetails(details(
                            "Project", name != null ? name
                                    : project != null
                                            ? "Name " + project.problem(
                                                    "the resourcemanager.projects.get permission")
                                            : null,
                            "Project ID", projectId,
                            "Project number", project != null && project.ok()
                                    ? jsonField(project.body(), "projectNumber") : null,
                            "State", project != null && project.ok()
                                    ? jsonField(project.body(), "lifecycleState") : null,
                            "Service account", clientEmail,
                            "Region", text(data, "region")));
        }
        String detail = jsonField(response.body(), "error_description");
        return Verification.failed("Google Cloud rejected the credentials (HTTP "
                + response.statusCode() + (detail != null ? "): " + detail : ")"));
    }


    /** RS256 JWT for the Google OAuth JWT-bearer grant, JDK crypto only. */
    private String signedJwt(String clientEmail, String privateKeyPem, String audience)
            throws Exception {
        String pkcs8 = privateKeyPem
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replaceAll("\\s", "");
        PrivateKey key = KeyFactory.getInstance("RSA")
                .generatePrivate(new PKCS8EncodedKeySpec(Base64.getDecoder().decode(pkcs8)));
        long now = Instant.now().getEpochSecond();
        String header = base64Url("{\"alg\":\"RS256\",\"typ\":\"JWT\"}");
        String claims = base64Url("{\"iss\":\"" + clientEmail + "\",\"scope\":\""
                + "https://www.googleapis.com/auth/cloud-platform\",\"aud\":\"" + audience
                + "\",\"iat\":" + now + ",\"exp\":" + (now + 300) + "}");
        Signature signature = Signature.getInstance("SHA256withRSA");
        signature.initSign(key);
        signature.update((header + "." + claims).getBytes(StandardCharsets.UTF_8));
        return header + "." + claims + "."
                + Base64.getUrlEncoder().withoutPadding().encodeToString(signature.sign());
    }

    // ------ KUBERNETES: the cluster answers /version ------

    private Verification verifyKubernetes(JsonNode data) throws Exception {
        String kubeconfig = text(data, "kubeconfig");
        if (kubeconfig == null) {
            return Verification.failed("Missing kubeconfig in the stored credentials");
        }
        // Same isolation as a kubernetes step: the kubeconfig belongs to one
        // throwaway user in one private directory, both gone when we return.
        try (StepWorkspace workspace = sandbox.acquire()) {
            return verifyKubernetes(kubeconfig, workspace);
        } catch (SandboxException ex) {
            return Verification.failed(ex.getMessage());
        }
    }

    private Verification verifyKubernetes(String kubeconfig, StepWorkspace workspace)
            throws Exception {
        Path kubeconfigFile = workspace.createFile("autoops-verify-kubeconfig-", ".yaml");
        try {
            Files.writeString(kubeconfigFile, kubeconfig, StandardCharsets.UTF_8);
            kubeconfigFile.toFile().setReadable(false, false);
            kubeconfigFile.toFile().setReadable(true, true);
            workspace.handOver(kubeconfigFile);
            Map<String, String> env = new HashMap<>(workspace.environment());
            env.put("KUBECONFIG", kubeconfigFile.toAbsolutePath().toString());
            ProcessSupport.ProcessResult result = ProcessSupport.run(
                    workspace.wrap(List.of("kubectl", "get", "--raw", "/version",
                            "--request-timeout=10s")),
                    env, workspace.workingDirectory(), TIMEOUT, 4000, List.of());
            if (result.timedOut()) {
                return Verification.failed("Cluster did not answer within "
                        + TIMEOUT.toSeconds() + "s");
            }
            if (result.exitCode() == 0) {
                String version = jsonField(result.output(), "gitVersion");
                Matcher context = KUBE_CONTEXT.matcher(kubeconfig);
                Matcher server = KUBE_SERVER.matcher(kubeconfig);
                String serverUrl = server.find() ? unquote(server.group(1)) : null;
                String contextName = context.find() ? unquote(context.group(1)) : null;
                return Verification.ok("Cluster reachable"
                                + (version != null ? " — Kubernetes " + version : ""))
                        .withAccount(serverUrl, contextName)
                        .withDetails(details(
                                "Context", contextName,
                                "API server", serverUrl,
                                "Version", version,
                                "Platform", jsonField(result.output(), "platform")));
            }
            return Verification.failed("kubectl could not reach the cluster: "
                    + result.output().lines().findFirst().orElse("exit "
                            + result.exitCode()));
        } finally {
            Files.deleteIfExists(kubeconfigFile);
        }
    }

    // ------------------------------------------------------------------

    /**
     * Whether the follow-up identity lookup may run. It is only safe to call
     * the provider's real resource API when we actually authenticated against
     * the provider's real token endpoint — an {@code endpoint} override means
     * a stub or a sovereign cloud, where the public resource URL is wrong.
     * An explicit {@code resourceEndpoint} says where to look instead.
     */
    private static boolean lookupAllowed(URI tokenUri, String resourceEndpoint,
                                         String officialTokenHost) {
        return resourceEndpoint != null || tokenUri.toString().startsWith(officialTokenHost);
    }

    /** status is 0 when the call could not be made at all. */
    private record Lookup(int status, String body) {

        boolean ok() {
            return status == 200 && body != null;
        }

        /**
         * Why the details are missing, phrased so the user can act on it.
         * 404 counts as a permission problem: ARM answers "not found" for a
         * subscription the caller cannot see, so it is indistinguishable from
         * a missing role assignment.
         */
        String problem(String remedy) {
            return status == 401 || status == 403 || status == 404
                    ? "Unavailable — " + remedy
                    : "Unavailable (HTTP " + (status == 0 ? "no response" : status) + ")";
        }
    }

    /** GET with a bearer token. Never throws — lookups are best-effort. */
    private Lookup bearerGet(String uri, String accessToken) {
        try {
            HttpResponse<String> response = send(HttpRequest.newBuilder(URI.create(uri))
                    .timeout(TIMEOUT)
                    .header("Authorization", "Bearer " + accessToken)
                    .GET()
                    .build());
            return new Lookup(response.statusCode(), response.body());
        } catch (Exception ex) {
            log.debug("Identity lookup at {} failed: {}", uri, ex.getMessage());
            return new Lookup(0, null);
        }
    }

    private HttpResponse<String> send(HttpRequest request) throws Exception {
        try (HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build()) {
            return client.send(request, HttpResponse.BodyHandlers.ofString());
        }
    }

    private String jsonField(String body, String field) {
        try {
            JsonNode node = objectMapper.readTree(body).path(field);
            return node.isTextual() && !node.asText().isBlank() ? node.asText() : null;
        } catch (Exception ex) {
            return null;
        }
    }

    private static String text(JsonNode data, String... keys) {
        if (data == null) {
            return null;
        }
        for (String key : keys) {
            JsonNode node = data.path(key);
            if (node.isTextual() && !node.asText().isBlank()) {
                // Trimmed: ids and keys are almost always pasted, and a
                // trailing newline silently corrupts the URL we build from
                // them (a stray space turns an ARM lookup into a 404).
                return node.asText().trim();
            }
        }
        return null;
    }

    private static String unquote(String value) {
        return value == null ? null : value.replaceAll("^[\"']|[\"']$", "");
    }

    private static String base64Url(String value) {
        return Base64.getUrlEncoder().withoutPadding()
                .encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    private void count(String platform, Verification verification) {
        if (meterRegistry != null) {
            meterRegistry.counter("job_credential_verifications_total",
                    "platform", platform.isEmpty() ? "unknown" : platform,
                    "outcome", !verification.supported() ? "unsupported"
                            : verification.verified() ? "ok" : "failed").increment();
        }
    }
}