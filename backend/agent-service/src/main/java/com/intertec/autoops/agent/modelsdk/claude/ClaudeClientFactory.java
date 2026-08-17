package com.intertec.autoops.agent.modelsdk.claude;

import com.anthropic.client.AnthropicClient;
import com.anthropic.client.okhttp.AnthropicOkHttpClient;
import com.intertec.autoops.agent.modelsdk.ModelCredentials;

/**
 * Claude, via Anthropic's own SDK.
 *
 * <p>This package is {@code claude} but the vendor kind is
 * {@link com.intertec.autoops.agent.modelsdk.ModelVendor#ANTHROPIC} — the
 * company and the model line have different names, and the console shows the
 * company's.
 *
 * <p>The SDK authenticates on {@code x-api-key} and sends the required
 * {@code anthropic-version} header itself; that is exactly the pair of details
 * a hand-rolled client gets wrong, and the reason this is not a raw HTTP call.
 * Keys are per-tenant, so nothing here reads {@code ANTHROPIC_API_KEY} from
 * the environment — a fallback to a platform key would silently bill us for a
 * tenant's work.
 */
public final class ClaudeClientFactory {

    private ClaudeClientFactory() {
    }

    public static AnthropicClient create(ModelCredentials credentials) {
        return AnthropicOkHttpClient.builder()
                .apiKey(credentials.require("apiKey"))
                .build();
    }
}
