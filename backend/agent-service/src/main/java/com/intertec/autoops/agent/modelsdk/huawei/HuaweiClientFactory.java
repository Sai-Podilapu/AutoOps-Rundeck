package com.intertec.autoops.agent.modelsdk.huawei;

import com.huaweicloud.sdk.core.auth.BasicCredentials;
import com.huaweicloud.sdk.modelarts.v1.ModelArtsClient;
import com.intertec.autoops.agent.modelsdk.ModelCredentials;

/**
 * Huawei Cloud Pangu / ModelArts, via Huawei's own SDK.
 *
 * <p>The awkward vendor: it needs an AK/SK pair, a region, AND a project id —
 * the project scopes the credentials, so a valid pair with the wrong project
 * authenticates and then finds nothing.
 *
 * <p>The endpoint is built from the region rather than taken from the SDK's
 * region enum: that enum only knows the regions present in the SDK release,
 * so a region Huawei added since would be unreachable even though the console
 * offers it and the signing works fine.
 */
public final class HuaweiClientFactory {

    private HuaweiClientFactory() {
    }

    public static ModelArtsClient create(ModelCredentials credentials) {
        String region = credentials.require("region");
        BasicCredentials auth = new BasicCredentials()
                .withAk(credentials.require("accessKey"))
                .withSk(credentials.require("secretKey"))
                .withProjectId(credentials.require("projectId"));
        return ModelArtsClient.newBuilder()
                .withCredential(auth)
                .withEndpoints(java.util.List.of(
                        "https://modelarts." + region + ".myhuaweicloud.com"))
                .build();
    }
}
