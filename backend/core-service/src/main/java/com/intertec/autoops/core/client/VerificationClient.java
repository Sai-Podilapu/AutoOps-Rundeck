package com.intertec.autoops.core.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.intertec.autoops.core.config.CoreProperties;
import com.intertec.autoops.core.exception.CoreException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.time.Duration;
import java.util.Map;

/**
 * Asks job-service to verify a credential bundle against the real cloud
 * provider (STS / Entra ID / Google OAuth / the cluster's /version). The
 * provider round-trip happens in the runtime container — this service never
 * talks to cloud APIs itself and the decrypted secret never crosses the
 * gateway.
 */
@Component
public class VerificationClient {

    private static final Logger log = LoggerFactory.getLogger(VerificationClient.class);

    private final RestClient restClient;
    private final CoreProperties properties;

    public VerificationClient(CoreProperties properties) {
        this.properties = properties;
        JdkClientHttpRequestFactory requestFactory = new JdkClientHttpRequestFactory();
        // The provider check itself is capped at 15s inside job-service.
        requestFactory.setReadTimeout(Duration.ofSeconds(25));
        this.restClient = RestClient.builder()
                .baseUrl(properties.getExecution().getJobServiceUrl())
                .requestFactory(requestFactory)
                .build();
    }

    /**
     * accountId/accountName are the provider's own identity, null if unknown;
     * details is an ordered map of provider-reported facts for display.
     */
    public record VerifyResult(boolean supported, boolean verified, String message,
                               String accountId, String accountName,
                               Map<String, String> details) {
    }

    public VerifyResult verify(String tenantId, String platform, JsonNode data) {
        try {
            Map<String, Object> response = restClient.post()
                    .uri("/internal/verify")
                    .header("X-Internal-Token", properties.getExecution().getJobServiceToken())
                    .body(Map.of("tenantId", tenantId, "platform", platform, "data", data))
                    .retrieve()
                    .body(new ParameterizedTypeReference<Map<String, Object>>() {
                    });
            if (response == null) {
                throw new IllegalStateException("empty response");
            }
            return new VerifyResult(Boolean.TRUE.equals(response.get("supported")),
                    Boolean.TRUE.equals(response.get("verified")),
                    response.get("message") != null ? response.get("message").toString() : "",
                    str(response.get("accountId")), str(response.get("accountName")),
                    details(response.get("details")));
        } catch (Exception ex) {
            log.warn("Credential verification call failed for tenant {}: {}", tenantId,
                    ex.getMessage());
            throw CoreException.serviceUnavailable("verification_unavailable",
                    "The verification runtime is unreachable — try again shortly");
        }
    }

    private static String str(Object value) {
        return value == null || value.toString().isBlank() ? null : value.toString();
    }

    /** Order matters — job-service sends the fields in display order. */
    @SuppressWarnings("unchecked")
    private static Map<String, String> details(Object value) {
        if (!(value instanceof Map<?, ?> raw)) {
            return Map.of();
        }
        Map<String, String> ordered = new java.util.LinkedHashMap<>();
        ((Map<String, Object>) raw).forEach((k, v) -> {
            if (v != null) {
                ordered.put(k, v.toString());
            }
        });
        return ordered;
    }
}