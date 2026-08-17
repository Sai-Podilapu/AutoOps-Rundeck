package com.intertec.autoops.agent.modelsdk.azure;

import com.azure.ai.openai.OpenAIClient;
import com.azure.ai.openai.OpenAIClientBuilder;
import com.azure.core.credential.AzureKeyCredential;
import com.intertec.autoops.agent.modelsdk.ModelCredentials;

/**
 * Azure OpenAI, via Azure's own SDK.
 *
 * <p>Azure has no global host: every tenant gets a resource endpoint, and
 * requests route on a DEPLOYMENT name the tenant chose, which need not match
 * the base model it serves. So a caller's "model" here is that deployment
 * name, and both it and the endpoint can only come from the stored config.
 *
 * <p>The returned type is {@code com.azure.ai.openai.OpenAIClient}, which is a
 * different class from the {@code com.openai.client.OpenAIClient} the
 * {@code openai} package returns despite the identical simple name — always
 * import deliberately when working across the two.
 */
public final class AzureOpenAiClientFactory {

    private AzureOpenAiClientFactory() {
    }

    public static OpenAIClient create(ModelCredentials credentials) {
        return new OpenAIClientBuilder()
                .endpoint(credentials.requireUrl("endpoint"))
                .credential(new AzureKeyCredential(credentials.require("apiKey")))
                .buildClient();
    }
}
