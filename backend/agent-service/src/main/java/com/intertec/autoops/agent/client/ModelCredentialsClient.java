package com.intertec.autoops.agent.client;

import com.intertec.autoops.agent.config.AgentProperties;
import com.intertec.autoops.agent.exception.AgentException;
import com.intertec.autoops.agent.modelsdk.ModelCredentials;
import com.intertec.autoops.agent.modelsdk.ModelVendor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Fetches the tenant's decrypted key for one model, for one call.
 *
 * <p>Nothing here is cached, and that is the point. A cached credential is a
 * secret sitting in this service's heap between runs, surviving a key rotation
 * the tenant thinks took effect immediately and outliving a provider they just
 * disabled. The cost of not caching is one internal HTTP call per agent run,
 * against a run that is about to spend seconds talking to a model.
 *
 * <p>The result is a {@link ModelCredentials}, which is deliberately
 * short-lived and redacts itself in {@code toString}.
 */
@Component
public class ModelCredentialsClient {

    private static final Logger log = LoggerFactory.getLogger(ModelCredentialsClient.class);

    private static final ParameterizedTypeReference<Map<String, Object>> MAP =
            new ParameterizedTypeReference<>() { };

    private final RestClient coreRestClient;
    private final String coreToken;

    public ModelCredentialsClient(@Qualifier("coreRestClient") RestClient coreRestClient,
                                  AgentProperties properties) {
        this.coreRestClient = coreRestClient;
        this.coreToken = properties.getCore().getInternalToken();
    }

    /** @param model the agent's model id, e.g. {@code claude-sonnet-4-5} */
    public record Resolved(ModelVendor vendor, String providerName, String model,
                           ModelCredentials credentials) {
    }

    @SuppressWarnings("unchecked")
    public Resolved resolve(String tenantId, String model) {
        Map<String, Object> response;
        try {
            response = coreRestClient.get()
                    .uri("/internal/model-credentials?tenantId={tenantId}&model={model}",
                            tenantId, model)
                    .header("X-Internal-Token", coreToken)
                    .retrieve()
                    .body(MAP);
        } catch (org.springframework.web.client.RestClientResponseException ex) {
            // core says which connection is missing, disabled or undecryptable.
            // That message is what the operator needs; replacing it with a
            // generic one would send them to the wrong screen.
            throw AgentException.badRequest("model_unavailable", message(ex));
        } catch (Exception ex) {
            throw AgentException.serviceUnavailable("core_unavailable",
                    "Could not reach the credential service: " + ex.getMessage());
        }
        if (response == null) {
            throw AgentException.serviceUnavailable("core_unavailable",
                    "The credential service returned nothing.");
        }

        String kind = String.valueOf(response.get("kind"));
        ModelVendor vendor = ModelVendor.fromCode(kind);
        if (vendor == null) {
            // ELEVENLABS, SAGEMAKER, OPENROUTER and HUGGINGFACE exist in core's
            // catalog and have no chat adapter here. Refusing by name beats a
            // NullPointerException three frames deeper.
            throw AgentException.badRequest("vendor_not_runnable",
                    "Model \"" + model + "\" is served by a " + kind + " connection, which "
                            + "agents cannot run on. Point the agent at an OpenAI, Anthropic, "
                            + "Google, Azure, Bedrock or compatible connection.");
        }

        Map<String, String> values = new LinkedHashMap<>();
        if (response.get("values") instanceof Map<?, ?> raw) {
            ((Map<String, Object>) raw).forEach((key, value) -> {
                if (value != null) {
                    values.put(key, String.valueOf(value));
                }
            });
        }

        String providerName = String.valueOf(response.getOrDefault("providerName", kind));
        String resolvedModel = String.valueOf(response.getOrDefault("model", model));
        log.debug("Resolved model {} for tenant {} to vendor {}", model, tenantId, vendor);

        return new Resolved(vendor, providerName, resolvedModel,
                ModelCredentials.of(vendor, values));
    }

    private static String message(org.springframework.web.client.RestClientResponseException ex) {
        String body = ex.getResponseBodyAsString();
        if (body != null && body.contains("\"message\"")) {
            int start = body.indexOf("\"message\"");
            int quote = body.indexOf('"', body.indexOf(':', start) + 1);
            int end = quote < 0 ? -1 : body.indexOf('"', quote + 1);
            if (quote > 0 && end > quote) {
                return body.substring(quote + 1, end);
            }
        }
        return ex.getStatusText();
    }
}
