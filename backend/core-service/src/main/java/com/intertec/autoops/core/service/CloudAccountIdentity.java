package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.intertec.autoops.core.domain.CloudAccountClaimKind;
import com.intertec.autoops.core.domain.CloudPlatform;

import java.net.URI;
import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Derives the values that identify a cloud account uniquely ACROSS TENANTS, so
 * {@link CloudAccountRegistry} can hold one account to one tenant.
 *
 * <p>Two kinds come out of a credential blob:
 * <ul>
 *   <li>ACCOUNT — the account the credentials point at. Provider-issued and
 *       globally unique by construction (AWS account number, Azure
 *       subscription GUID, GCP project id, Entra tenant, OCI tenancy). Rotating
 *       a key does not change it, so it catches the same account arriving under
 *       a second tenant with a fresh key pair.</li>
 *   <li>CREDENTIAL — the authenticating material itself. Known the instant it
 *       is submitted, with no provider round-trip, which is what stops leaked
 *       credentials from being pasted into another tenant.</li>
 * </ul>
 *
 * <p>A value only becomes a claim when it is genuinely globally unique. That
 * cuts the other way from the rest of this feature: a FALSE match locks a
 * paying customer out of their own account, so anything that many tenants could
 * plausibly present in common — a private or in-cluster Kubernetes endpoint, a
 * too-short placeholder — is deliberately left unclaimed. The CREDENTIAL claim
 * still covers those cases, because credential material is high-entropy by
 * definition.
 *
 * <p>Pure and side-effect free: nothing here reads the database, and no value
 * returned by it is ever stored — the registry hashes it first.
 */
public final class CloudAccountIdentity {

    /** One identifying value, plus what it identifies. */
    public record Claim(CloudAccountClaimKind kind, String value) {
    }

    /**
     * An account identifier shorter than this is a placeholder, not an
     * identity, and is not worth risking a false match on.
     */
    private static final int MIN_ACCOUNT_LENGTH = 6;

    /** Credential material is high-entropy; anything this short is a stub. */
    private static final int MIN_CREDENTIAL_LENGTH = 8;

    /** The cluster endpoint inside a kubeconfig, without parsing YAML. */
    private static final Pattern KUBE_SERVER = Pattern.compile("server:\\s*(\\S+)");

    /** Runs of whitespace, so kubeconfig reformatting is not a new identity. */
    private static final Pattern WHITESPACE = Pattern.compile("\\s+");

    /** Endpoints that resolve differently for every tenant that uses them. */
    private static final Set<String> LOCAL_HOSTS =
            Set.of("localhost", "kubernetes", "kubernetes.default");

    private static final Set<String> LOCAL_SUFFIXES =
            Set.of(".local", ".internal", ".svc", ".lan", ".home", ".localdomain");

    private CloudAccountIdentity() {
    }

    /**
     * @param credentials       decrypted credential map, or null when the
     *                          connection has none stored
     * @param verifiedAccountId identity the provider itself reported, or null
     *                          before the first successful verification. Claimed
     *                          ALONGSIDE the typed identity rather than instead
     *                          of it — a tenant that typed one subscription and
     *                          authenticates into another holds both.
     */
    public static Set<Claim> of(CloudPlatform platform, JsonNode credentials,
                                String verifiedAccountId) {
        Set<Claim> claims = new LinkedHashSet<>();
        if (platform == null) {
            return claims;
        }
        switch (platform) {
            case AWS -> {
                // Pre-verification an AWS caller only reveals its access key —
                // the 12-digit account number comes from STS.
                account(claims, verifiedAccountId);
                credential(claims, text(credentials, "accessId", "accessKey", "accessKeyId"));
            }
            case AZURE -> {
                account(claims, text(credentials, "subscriptionId"));
                account(claims, verifiedAccountId);
                credential(claims, pair(text(credentials, "clientId"),
                        text(credentials, "tenantId")));
            }
            case GCP -> {
                account(claims, text(credentials, "projectId"));
                account(claims, verifiedAccountId);
                credential(claims, pair(serviceAccountField(credentials, "client_email"),
                        serviceAccountField(credentials, "private_key_id")));
            }
            case HUAWEI -> {
                account(claims, text(credentials, "projectId", "domainId"));
                account(claims, verifiedAccountId);
                credential(claims, text(credentials, "ak", "accessKey", "accessKeyId"));
            }
            case ORACLE -> {
                account(claims, text(credentials, "tenancyOcid"));
                account(claims, verifiedAccountId);
                credential(claims, pair(text(credentials, "userOcid"),
                        text(credentials, "fingerprint")));
            }
            case M365 -> {
                account(claims, text(credentials, "tenantId"));
                account(claims, verifiedAccountId);
                credential(claims, pair(text(credentials, "clientId"),
                        text(credentials, "tenantId")));
            }
            case KUBERNETES -> {
                // 10.0.0.1:6443 belongs to as many clusters as there are
                // customers — only a publicly-resolvable endpoint identifies one.
                account(claims, publicEndpoint(kubernetesServer(credentials)));
                account(claims, publicEndpoint(verifiedAccountId));
                credential(claims, collapse(text(credentials, "kubeconfig")));
            }
        }
        return claims;
    }

    private static void account(Set<Claim> claims, String value) {
        add(claims, CloudAccountClaimKind.ACCOUNT, value, MIN_ACCOUNT_LENGTH);
    }

    private static void credential(Set<Claim> claims, String value) {
        add(claims, CloudAccountClaimKind.CREDENTIAL, value, MIN_CREDENTIAL_LENGTH);
    }

    private static void add(Set<Claim> claims, CloudAccountClaimKind kind, String value,
                            int minLength) {
        if (value == null) {
            return;
        }
        String normalized = value.trim().toLowerCase(Locale.ROOT);
        if (normalized.length() < minLength) {
            return;
        }
        claims.add(new Claim(kind, normalized));
    }

    /**
     * Two fields that together name one principal. Null unless the PRIMARY
     * (secret-bearing) field is present — an Azure tenant id on its own is
     * public directory metadata, not a credential.
     */
    private static String pair(String primary, String secondary) {
        if (primary == null) {
            return null;
        }
        return secondary == null ? primary : primary + "|" + secondary;
    }

    /** Cluster endpoint, e.g. https://abc.eks.amazonaws.com — never the token. */
    private static String kubernetesServer(JsonNode credentials) {
        String kubeconfig = text(credentials, "kubeconfig");
        if (kubeconfig == null) {
            return null;
        }
        Matcher matcher = KUBE_SERVER.matcher(kubeconfig);
        return matcher.find() ? matcher.group(1).replaceAll("^[\"']|[\"']$", "") : null;
    }

    /**
     * Keeps only endpoints that mean the same cluster no matter who resolves
     * them. IP literals, single-label names and in-cluster suffixes are shared
     * by unrelated tenants, so claiming them would lock out the second one.
     */
    static String publicEndpoint(String endpoint) {
        if (endpoint == null || endpoint.isBlank()) {
            return null;
        }
        String host;
        try {
            URI uri = URI.create(endpoint.trim());
            host = uri.getHost() != null ? uri.getHost() : uri.getPath();
        } catch (IllegalArgumentException ex) {
            return null;
        }
        if (host == null || host.isBlank()) {
            return null;
        }
        host = host.toLowerCase(Locale.ROOT);
        if (LOCAL_HOSTS.contains(host) || !host.contains(".")) {
            return null;
        }
        if (host.matches("\\d{1,3}(\\.\\d{1,3}){3}")) {
            return null; // an IPv4 literal names a network, not a cluster
        }
        for (String suffix : LOCAL_SUFFIXES) {
            if (host.endsWith(suffix)) {
                return null;
            }
        }
        // Keep the port: two clusters can sit behind one public name.
        String port = "";
        try {
            int explicit = URI.create(endpoint.trim()).getPort();
            port = explicit > 0 ? ":" + explicit : "";
        } catch (IllegalArgumentException ignored) {
            // hostless value; the host alone identifies it
        }
        return host + port;
    }

    /** Reformatting a kubeconfig must not read as a different credential. */
    private static String collapse(String value) {
        return value == null ? null : WHITESPACE.matcher(value.trim()).replaceAll(" ");
    }

    /** A field inside the pasted service-account JSON, without re-parsing it. */
    private static String serviceAccountField(JsonNode credentials, String field) {
        String json = text(credentials, "serviceAccount", "serviceAccountJson");
        if (json == null) {
            return null;
        }
        Matcher matcher = Pattern.compile("\"" + Pattern.quote(field) + "\"\\s*:\\s*\"([^\"]+)\"")
                .matcher(json);
        return matcher.find() ? matcher.group(1) : null;
    }

    private static String text(JsonNode data, String... keys) {
        if (data == null) {
            return null;
        }
        for (String key : keys) {
            JsonNode node = data.path(key);
            if (node.isTextual() && !node.asText().isBlank()) {
                return node.asText().trim();
            }
        }
        return null;
    }
}