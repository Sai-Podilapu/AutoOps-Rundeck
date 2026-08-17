package com.intertec.autoops.agent.loop;

import com.intertec.autoops.agent.exception.AgentException;
import com.intertec.autoops.agent.modelsdk.ModelVendor;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * Picks the adapter for a vendor.
 *
 * <p>Six adapters cover all eleven vendors: Anthropic; the OpenAI wire format
 * that OpenAI, Mistral, Groq, DeepSeek, xAI and Ollama share; Azure OpenAI;
 * Bedrock via Converse; Gemini; and Huawei against a ModelArts inference
 * endpoint.
 *
 * <p>The lookup still refuses rather than guesses. Nothing falls back to
 * another adapter when a vendor is unrecognised: an agent configured for
 * Bedrock that quietly ran on OpenAI would bill the wrong account and send the
 * tenant's data to a vendor they did not choose, and it would do it silently.
 */
@Component
public class ChatModels {

    private final List<ChatModel> adapters;

    public ChatModels(List<ChatModel> adapters) {
        this.adapters = List.copyOf(adapters);
    }

    public ChatModel forVendor(ModelVendor vendor) {
        return adapters.stream()
                .filter(adapter -> adapter.supports(vendor))
                .findFirst()
                .orElseThrow(() -> AgentException.badRequest("vendor_not_runnable",
                        "No agent-loop adapter for vendor " + vendor + "."));
    }

    /** Whether an agent can actually be run on this vendor today. */
    public boolean isRunnable(ModelVendor vendor) {
        return adapters.stream().anyMatch(adapter -> adapter.supports(vendor));
    }
}
