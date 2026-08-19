package com.intertec.autoops.jobs.execution;

import com.fasterxml.jackson.databind.JsonNode;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

/**
 * A cloud integration's credentials, as the environment variables every SDK
 * already knows how to find.
 *
 * <p>This was inside {@code TerraformRunner}, which was the only runner that
 * needed it. It is here now because it turned out to be the thing standing
 * between a large library of cloud automations and being able to run any of
 * them: a {@code pyscript} step importing boto3, or a {@code powershell} step
 * importing AWS.Tools, sees no credentials at all unless something puts them
 * in the environment. Terraform could reach a customer's AWS account and a
 * Python script could not, for no better reason than where this method lived.
 *
 * <p><b>Why environment variables rather than a config file.</b> Every vendor
 * SDK reads this same set — boto3 reads {@code AWS_ACCESS_KEY_ID}, the Azure
 * SDKs read {@code AZURE_CLIENT_ID}, terraform reads {@code ARM_*}. Writing a
 * credentials file instead would mean each runner inventing a location, and a
 * file outlives the process that made it.
 *
 * <p><b>Both spellings for Azure.</b> Terraform wants {@code ARM_*}; the Azure
 * SDKs and {@code Connect-AzAccount} want {@code AZURE_*}. They carry the same
 * four values, so emitting both costs nothing and removes an entire class of
 * "it works in terraform but not in Python" question.
 *
 * <p>Nothing here is logged, and the map is short-lived by construction: it is
 * built, handed to one {@link ProcessBuilder}, and dropped.
 */
public final class CloudCredentialEnv {

    private CloudCredentialEnv() {
    }

    /**
     * @param credentials the {@code {"platform","connection","data"}} bundle
     *                    core-service attached, or null when the step has no
     *                    integration bound to it
     * @param workDir     where a file-based credential may be written. GCP is
     *                    the only platform that needs one, and it goes in the
     *                    step's own private workspace rather than anywhere
     *                    shared.
     * @return the variables to overlay, never null and possibly empty
     */
    public static Map<String, String> forBundle(JsonNode credentials, Path workDir)
            throws IOException {
        Map<String, String> env = new HashMap<>();
        if (credentials == null || credentials.isMissingNode() || credentials.isNull()) {
            return env;
        }
        String platform = credentials.path("platform").asText("");
        JsonNode data = credentials.path("data");

        switch (platform) {
            case "AWS" -> {
                put(env, "AWS_ACCESS_KEY_ID", first(data, "accessId", "accessKey", "accessKeyId"));
                put(env, "AWS_SECRET_ACCESS_KEY",
                        first(data, "secret", "secretKey", "secretAccessKey"));
                // Some integrations are role-assumed and carry a session token.
                // Omitting it turns a valid temporary credential into an opaque
                // "InvalidClientTokenId" several frames from the cause.
                put(env, "AWS_SESSION_TOKEN", first(data, "sessionToken", "token"));
                put(env, "AWS_DEFAULT_REGION", first(data, "region"));
                put(env, "AWS_REGION", first(data, "region"));
            }
            case "AZURE" -> {
                String clientId = first(data, "clientId");
                String clientSecret = first(data, "clientSecret");
                String tenantId = first(data, "tenantId");
                String subscriptionId = first(data, "subscriptionId");

                put(env, "ARM_CLIENT_ID", clientId);
                put(env, "ARM_CLIENT_SECRET", clientSecret);
                put(env, "ARM_TENANT_ID", tenantId);
                put(env, "ARM_SUBSCRIPTION_ID", subscriptionId);

                // What the Azure SDKs and Connect-AzAccount actually read.
                put(env, "AZURE_CLIENT_ID", clientId);
                put(env, "AZURE_CLIENT_SECRET", clientSecret);
                put(env, "AZURE_TENANT_ID", tenantId);
                put(env, "AZURE_SUBSCRIPTION_ID", subscriptionId);
            }
            case "GCP" -> {
                String serviceAccount = first(data, "serviceAccount", "serviceAccountJson");
                if (serviceAccount != null && workDir != null) {
                    Path saFile = workDir.resolve("gcp-sa.json");
                    Files.writeString(saFile, serviceAccount, StandardCharsets.UTF_8);
                    env.put("GOOGLE_APPLICATION_CREDENTIALS", saFile.toAbsolutePath().toString());
                    env.put("GOOGLE_CREDENTIALS", serviceAccount);
                }
                put(env, "GOOGLE_PROJECT", first(data, "projectId"));
            }
            default -> {
                // Unknown or absent platform: no variables. The step decides
                // what it needs, and guessing would put a half-set credential
                // in front of an SDK that then fails somewhere less obvious.
            }
        }
        return env;
    }

    /** The first of several accepted spellings that is actually present. */
    private static String first(JsonNode data, String... keys) {
        for (String key : keys) {
            JsonNode node = data.path(key);
            if (node.isTextual() && !node.asText().isBlank()) {
                return node.asText();
            }
        }
        return null;
    }

    private static void put(Map<String, String> env, String name, String value) {
        if (value != null && !value.isBlank()) {
            env.put(name, value);
        }
    }
}
