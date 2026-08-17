package com.intertec.autoops.agent.modelsdk.openai;

import com.intertec.autoops.agent.modelsdk.ModelCredentials;
import com.intertec.autoops.agent.modelsdk.ModelVendor;
import com.openai.client.OpenAIClient;
import com.openai.client.okhttp.OpenAIOkHttpClient;

/**
 * OpenAI — and the five vendors that speak its wire format.
 *
 * <p>Mistral, Groq, DeepSeek, xAI and Ollama all document "point an OpenAI
 * client at our host", so they are served here with a different base URL
 * rather than five more SDKs. The difference between them is one string,
 * carried on {@link ModelVendor#baseUrl()}.
 *
 * <p>Ollama is the odd one twice over: the host is the tenant's own, and it
 * has no secret at all — whoever can reach the URL can use the models. Its
 * OpenAI-compatible surface still expects SOME bearer token, so a placeholder
 * goes in unless a gateway in front of it needs a real one.
 */
public final class OpenAiClientFactory {

    private OpenAiClientFactory() {
    }

    public static OpenAIClient create(ModelCredentials credentials) {
        ModelVendor vendor = credentials.vendor();
        OpenAIOkHttpClient.Builder builder = OpenAIOkHttpClient.builder();

        String baseUrl = vendor == ModelVendor.OLLAMA
                ? credentials.requireUrl("baseUrl") + "/v1"
                : vendor.baseUrl();
        if (baseUrl != null && !baseUrl.isBlank()) {
            builder.baseUrl(baseUrl);
        }

        builder.apiKey(vendor == ModelVendor.OLLAMA
                ? credentials.orElse("apiKey", "ollama")
                : credentials.require("apiKey"));

        return builder.build();
    }
}
