package com.intertec.autoops.agent.loop;

import com.intertec.autoops.agent.exception.AgentException;
import com.intertec.autoops.agent.modelsdk.ModelCredentials;
import com.intertec.autoops.agent.modelsdk.ModelVendor;
import com.openai.client.OpenAIClient;
import com.openai.client.okhttp.OpenAIOkHttpClient;
import org.springframework.stereotype.Component;

/**
 * Huawei Pangu / ModelArts.
 *
 * <p>This is the one vendor whose own SDK cannot serve the loop. The
 * {@code huaweicloud-sdk-modelarts} client on the classpath manages inference
 * SERVICES - creating them, binding API keys, deleting them, attaching
 * storage - and has no method that calls one. {@link HuaweiClientFactory}
 * remains correct for what it does; it just is not a chat client.
 *
 * <p>What a deployed ModelArts LLM service does expose is an OpenAI-compatible
 * {@code /v1/chat/completions} endpoint, which is how Pangu and vLLM-served
 * models on ModelArts are actually called. So this adapter takes the tenant's
 * own inference endpoint and speaks that wire format to it, reusing the OpenAI
 * mapping rather than duplicating it.
 *
 * <p>That is an assumption about how the service was deployed, and it is made
 * explicitly rather than silently: the endpoint is a REQUIRED credential with
 * no default. A ModelArts service published without the OpenAI-compatible
 * surface will fail on the first call with the endpoint's own error, which is
 * the right place to find out - not here, and not in a fallback that quietly
 * routed the tenant's traffic somewhere else.
 */
@Component
public class HuaweiChatModel implements ChatModel {

    private final OpenAiChatModel openAiMapping;

    public HuaweiChatModel(OpenAiChatModel openAiMapping) {
        this.openAiMapping = openAiMapping;
    }

    @Override
    public boolean supports(ModelVendor vendor) {
        return vendor == ModelVendor.HUAWEI;
    }

    @Override
    public ChatResponse chat(Request request) {
        ModelCredentials credentials = request.credentials();

        String endpoint = credentials.orElse("inferenceEndpoint", null);
        if (endpoint == null || endpoint.isBlank()) {
            throw AgentException.badRequest("huawei_endpoint_missing",
                    "Running an agent on Huawei needs the ModelArts inference endpoint of the "
                            + "deployed service, as credential 'inferenceEndpoint'. The ModelArts "
                            + "SDK manages services but cannot call them, so there is nothing to "
                            + "fall back to.");
        }

        // The service's own key. ModelArts issues these per inference service
        // (see batchBindInferApiKeys); it is not the account AK/SK the
        // management SDK uses, and substituting one for the other 401s.
        String apiKey = credentials.orElse("inferenceApiKey", null);
        if (apiKey == null || apiKey.isBlank()) {
            apiKey = credentials.require("apiKey");
        }

        OpenAIClient client = OpenAIOkHttpClient.builder()
                .baseUrl(normalise(endpoint))
                .apiKey(apiKey)
                .build();

        return openAiMapping.chatWith(client, request);
    }

    /**
     * ModelArts endpoints are published with and without the {@code /v1}
     * suffix depending on where in the console they were copied from, and the
     * OpenAI client appends the rest of the path itself. Normalising here
     * saves a 404 that reads like the model is missing.
     */
    private String normalise(String endpoint) {
        String trimmed = endpoint.trim();
        while (trimmed.endsWith("/")) {
            trimmed = trimmed.substring(0, trimmed.length() - 1);
        }
        return trimmed.endsWith("/v1") ? trimmed : trimmed + "/v1";
    }
}
