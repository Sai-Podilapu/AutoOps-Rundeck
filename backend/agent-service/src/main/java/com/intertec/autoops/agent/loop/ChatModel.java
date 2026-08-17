package com.intertec.autoops.agent.loop;

import com.intertec.autoops.agent.modelsdk.ModelCredentials;
import com.intertec.autoops.agent.modelsdk.ModelVendor;

import java.util.List;

/**
 * One model call, whichever vendor is behind it.
 *
 * <p>This is the adapter the {@code modelsdk} package deliberately left
 * unwritten. Its note said the shared interface should wait for the loop that
 * would consume it, so that its shape came from a real caller rather than a
 * guess; this is that shape, and the loop is the only caller.
 *
 * <p>Implementations are stateless. Credentials arrive per call because they
 * are the tenant's, decrypted for the length of one request - an implementation
 * that cached a configured client would outlive the credential and, worse,
 * serve one tenant's agent from another tenant's key.
 */
public interface ChatModel {

    /** Which vendors this adapter speaks for. */
    boolean supports(ModelVendor vendor);

    ChatResponse chat(Request request);

    /**
     * @param system     the agent's persona. Separate from {@code messages}
     *                   because the vendors carry it differently - a top-level
     *                   field on Anthropic, a first message on OpenAI - and
     *                   flattening it into the history here would force one of
     *                   the adapters to unpick it again.
     * @param maxTokens  ceiling on ONE reply. Not a budget for the whole run;
     *                   the run's ceiling is its step count.
     */
    record Request(ModelVendor vendor,
                   ModelCredentials credentials,
                   String model,
                   String system,
                   List<ChatMessage> messages,
                   List<ToolSpec> tools,
                   int maxTokens) {

        public Request {
            messages = List.copyOf(messages);
            tools = tools == null ? List.of() : List.copyOf(tools);
        }
    }
}
