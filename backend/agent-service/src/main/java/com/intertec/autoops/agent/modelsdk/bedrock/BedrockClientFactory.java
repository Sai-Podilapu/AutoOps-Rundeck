package com.intertec.autoops.agent.modelsdk.bedrock;

import com.intertec.autoops.agent.modelsdk.ModelCredentials;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.bedrockruntime.BedrockRuntimeClient;

/**
 * AWS Bedrock, via the AWS SDK v2.
 *
 * <p>The credentials are STATIC and explicit on purpose. The AWS SDK's default
 * provider chain would otherwise fall back to the container's own role or
 * environment — which, on a platform that runs many tenants, means one
 * tenant's agent quietly billing another account. Only the access key pair
 * this workspace stored is ever used.
 *
 * <p>Bedrock model ids are region-specific, and a model must be enabled for
 * the account before it can be invoked; a valid key in the wrong region fails
 * at invoke time, not here.
 */
public final class BedrockClientFactory {

    private BedrockClientFactory() {
    }

    public static BedrockRuntimeClient create(ModelCredentials credentials) {
        AwsBasicCredentials keys = AwsBasicCredentials.create(
                credentials.require("accessKeyId"),
                credentials.require("secretAccessKey"));
        return BedrockRuntimeClient.builder()
                .region(Region.of(credentials.require("region")))
                .credentialsProvider(StaticCredentialsProvider.create(keys))
                .build();
    }
}
