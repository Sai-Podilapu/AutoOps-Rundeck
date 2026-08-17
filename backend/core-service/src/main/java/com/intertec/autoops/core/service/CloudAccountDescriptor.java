package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.intertec.autoops.core.domain.CloudPlatform;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Derives the NON-SECRET identity of a cloud connection — which account it
 * points at and in which region — so the UI can show something meaningful
 * instead of the auto-generated connection name.
 *
 * <p>Only fields that identify an account are exposed; anything that
 * authenticates (secret keys, client secrets, private keys, kubeconfig
 * contents) never leaves this service. The one credential-shaped value we do
 * surface is the AWS access key ID, and it is masked — it is an identifier,
 * not the secret, but there is no reason to print it in full.
 *
 * <p>For AWS the real 12-digit account number is only knowable from the
 * provider, so a successful STS verification is preferred over the local
 * key when available.
 */
public final class CloudAccountDescriptor {

    /**
     * Account identity and region; any part may be null when unknowable.
     * accountName only ever comes from the provider — it is not something the
     * user typed, so it appears once the connection has been verified.
     */
    public record AccountInfo(String accountId, String accountName, String region) {

        public static final AccountInfo EMPTY = new AccountInfo(null, null, null);
    }

    /** The account number inside an STS ARN: arn:aws:iam::123456789012:user/x */
    private static final Pattern ARN_ACCOUNT = Pattern.compile(":(\\d{12}):");
    /** The cluster endpoint inside a kubeconfig, without parsing YAML. */
    private static final Pattern KUBE_SERVER = Pattern.compile("server:\\s*(\\S+)");

    private CloudAccountDescriptor() {
    }

    /**
     * @param credentials decrypted credential map, or null when the connection
     *                    has none stored
     * @param verifiedAccountId   identity the provider reported at the last
     *                            verification; authoritative when present
     * @param verifiedAccountName the provider's display name for that account
     * @param verifiedMessage the last verification message — still parsed for
     *                        the AWS account number so connections verified
     *                        before the identity fields existed keep working
     */
    public static AccountInfo describe(CloudPlatform platform, JsonNode credentials,
                                       String verifiedAccountId, String verifiedAccountName,
                                       String verifiedMessage) {
        if (platform == null) {
            return AccountInfo.EMPTY;
        }
        AccountInfo local = fromCredentials(platform, credentials, verifiedMessage);
        // The provider's own answer beats anything derived from what was typed.
        return new AccountInfo(
                firstNonNull(verifiedAccountId, local.accountId()),
                firstNonNull(verifiedAccountName, local.accountName()),
                local.region());
    }

    private static AccountInfo fromCredentials(CloudPlatform platform, JsonNode credentials,
                                               String verifiedMessage) {
        return switch (platform) {
            case AWS -> new AccountInfo(
                    firstNonNull(awsAccountFromArn(verifiedMessage),
                            mask(text(credentials, "accessId", "accessKey", "accessKeyId"))),
                    null, text(credentials, "region"));
            case AZURE -> new AccountInfo(
                    text(credentials, "subscriptionId", "tenantId"), null,
                    text(credentials, "region", "location"));
            case GCP -> new AccountInfo(
                    firstNonNull(text(credentials, "projectId"),
                            gcpServiceAccountEmail(credentials)),
                    gcpServiceAccountEmail(credentials), text(credentials, "region"));
            case HUAWEI -> new AccountInfo(
                    text(credentials, "projectId"), null, text(credentials, "region"));
            case ORACLE -> new AccountInfo(
                    shorten(text(credentials, "tenancyOcid"), 28), null,
                    text(credentials, "region"));
            case M365 -> new AccountInfo(text(credentials, "tenantId"), null, null);
            case KUBERNETES -> new AccountInfo(kubernetesServer(credentials), null, null);
        };
    }

    /** The 12-digit account number STS reported at the last verification. */
    private static String awsAccountFromArn(String verifiedMessage) {
        if (verifiedMessage == null) {
            return null;
        }
        Matcher matcher = ARN_ACCOUNT.matcher(verifiedMessage);
        return matcher.find() ? matcher.group(1) : null;
    }

    /** Cluster endpoint, e.g. https://10.0.0.1:6443 — never the credentials. */
    private static String kubernetesServer(JsonNode credentials) {
        String kubeconfig = text(credentials, "kubeconfig");
        if (kubeconfig == null) {
            return null;
        }
        Matcher matcher = KUBE_SERVER.matcher(kubeconfig);
        return matcher.find() ? stripQuotes(matcher.group(1)) : null;
    }

    /** The service account's own address identifies the GCP principal. */
    private static String gcpServiceAccountEmail(JsonNode credentials) {
        String json = text(credentials, "serviceAccount", "serviceAccountJson");
        if (json == null) {
            return null;
        }
        Matcher matcher = Pattern.compile("\"client_email\"\\s*:\\s*\"([^\"]+)\"").matcher(json);
        return matcher.find() ? matcher.group(1) : null;
    }

    /** AKIAIOSFODNN7EXAMPLE -> AKIA••••••••MPLE */
    private static String mask(String value) {
        if (value == null) {
            return null;
        }
        if (value.length() <= 8) {
            return "•".repeat(value.length());
        }
        return value.substring(0, 4) + "•".repeat(Math.min(8, value.length() - 8))
                + value.substring(value.length() - 4);
    }

    private static String shorten(String value, int max) {
        if (value == null || value.length() <= max) {
            return value;
        }
        return value.substring(0, max - 4) + "…" + value.substring(value.length() - 3);
    }

    private static String stripQuotes(String value) {
        return value.replaceAll("^[\"']|[\"']$", "");
    }

    private static String firstNonNull(String a, String b) {
        return a != null ? a : b;
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
