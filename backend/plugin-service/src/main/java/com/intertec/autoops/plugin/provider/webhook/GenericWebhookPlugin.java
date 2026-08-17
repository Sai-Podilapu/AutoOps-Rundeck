package com.intertec.autoops.plugin.provider.webhook;

import com.intertec.autoops.plugin.provider.support.OutboundHttp;
import com.intertec.autoops.plugin.spi.ConfigField;
import com.intertec.autoops.plugin.spi.DeliveryResult;
import com.intertec.autoops.plugin.spi.NotificationMessage;
import com.intertec.autoops.plugin.spi.NotificationPlugin;
import com.intertec.autoops.plugin.spi.PluginContext;
import com.intertec.autoops.plugin.spi.PluginDescriptor;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.http.HttpHeaders;
import org.springframework.stereotype.Component;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

/**
 * A plain JSON webhook, for PagerDuty Events v2, Opsgenie, Discord-compatible
 * receivers, or anything the tenant writes themselves.
 *
 * <p>Carries the platform's existing {@code GENERIC_WEBHOOK} connector kind
 * forward, so nothing is lost when installations migrate off {@code
 * ConnectorService}.
 *
 * <p>Optionally HMAC-signs the body. Without a signature the receiver cannot
 * tell an AutoOps notification from anyone else who learned the URL, so any
 * endpoint that acts on these events should set a signing secret.
 */
@Component
public class GenericWebhookPlugin implements NotificationPlugin {

    static final String URL = "url";
    static final String SIGNING_SECRET = "signingSecret";
    static final String HEADER_NAME = "headerName";
    static final String HEADER_VALUE = "headerValue";

    /** Header names match the convention GitHub and Stripe established. */
    private static final String SIGNATURE_HEADER = "X-AutoOps-Signature";
    private static final String TIMESTAMP_HEADER = "X-AutoOps-Timestamp";
    private static final String EVENT_HEADER = "X-AutoOps-Event";
    private static final String HMAC_ALGORITHM = "HmacSHA256";

    private final OutboundHttp http;
    private final ObjectMapper objectMapper;

    public GenericWebhookPlugin(OutboundHttp http, ObjectMapper objectMapper) {
        this.http = http;
        this.objectMapper = objectMapper;
    }

    @Override
    public PluginDescriptor descriptor() {
        return new PluginDescriptor(
                "webhook",
                "Webhook",
                PluginDescriptor.Category.CHAT,
                "POST job and workflow events as JSON to any HTTPS endpoint.",
                null,
                List.of(
                        ConfigField.url(URL, "Endpoint URL", true,
                                        "Receives an HTTPS POST with a JSON body.")
                                .withPlaceholder("https://events.example.com/autoops"),
                        ConfigField.secret(SIGNING_SECRET, "Signing secret", false,
                                "If set, each request carries an " + SIGNATURE_HEADER
                                        + " header: HMAC-SHA256 of \"{timestamp}.{body}\", hex."),
                        ConfigField.text(HEADER_NAME, "Extra header name", false,
                                        "For endpoints that need an API key header.")
                                .withPlaceholder("Authorization"),
                        ConfigField.secret(HEADER_VALUE, "Extra header value", false,
                                "Sent with the header name above.")));
    }

    @Override
    public DeliveryResult send(PluginContext context, NotificationMessage message) {
        return post(context, payload(message), message.event().name());
    }

    /**
     * Posts a {@code connection.test} event rather than a fake run. A receiver
     * can ignore it by type; inventing a job event to test with would put a
     * lie into the tenant's incident history.
     */
    @Override
    public DeliveryResult verify(PluginContext context) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("type", "connection.test");
        body.put("tenantId", context.tenantId());
        body.put("integration", context.displayName());
        body.put("occurredAt", Instant.now().toString());
        body.put("message", "AutoOps connection test — no job or workflow ran.");
        return post(context, body, "connection.test");
    }

    private DeliveryResult post(PluginContext context, Map<String, Object> body, String eventName) {
        String json;
        try {
            // Serialised here, not by the client, because the signature must
            // cover the exact bytes that go on the wire.
            json = objectMapper.writeValueAsString(body);
        } catch (JsonProcessingException ex) {
            return DeliveryResult.failure("Could not serialise the payload: " + ex.getMessage());
        }
        return http.postJson(context.require(URL), json, headers(context, json, eventName));
    }

    private Consumer<HttpHeaders> headers(PluginContext context, String json, String eventName) {
        String timestamp = String.valueOf(Instant.now().getEpochSecond());
        String secret = context.optional(SIGNING_SECRET, null);
        String extraName = context.optional(HEADER_NAME, null);
        String extraValue = context.optional(HEADER_VALUE, null);
        return headers -> {
            headers.set(EVENT_HEADER, eventName);
            headers.set(TIMESTAMP_HEADER, timestamp);
            if (secret != null) {
                // Timestamp inside the signed payload so a captured request
                // cannot be replayed later with its signature intact.
                headers.set(SIGNATURE_HEADER, sign(secret, timestamp + "." + json));
            }
            if (extraName != null && extraValue != null) {
                headers.set(extraName, extraValue);
            }
        };
    }

    private Map<String, Object> payload(NotificationMessage message) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("type", "run." + message.event().name().toLowerCase());
        body.put("event", message.event().name());
        body.put("severity", message.severity().name());
        body.put("title", message.title());
        body.put("tenantId", message.tenantId());
        body.put("targetType", message.targetType().name());
        body.put("targetId", message.targetId());
        body.put("targetName", message.targetName());
        body.put("projectId", message.projectId());
        body.put("projectName", message.projectName());
        body.put("runId", message.runId());
        body.put("triggeredBy", message.triggeredBy());
        body.put("detail", message.detail());
        body.put("durationSeconds", message.duration() == null ? null : message.duration().toSeconds());
        body.put("occurredAt", message.occurredAt().toString());
        body.put("consoleUrl", message.consoleUrl());
        return body;
    }

    private static String sign(String secret, String payload) {
        try {
            Mac mac = Mac.getInstance(HMAC_ALGORITHM);
            mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), HMAC_ALGORITHM));
            byte[] digest = mac.doFinal(payload.getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder(digest.length * 2);
            for (byte b : digest) {
                hex.append(Character.forDigit((b >> 4) & 0xf, 16))
                        .append(Character.forDigit(b & 0xf, 16));
            }
            return hex.toString();
        } catch (Exception ex) {
            throw new IllegalStateException("Cannot sign webhook payload", ex);
        }
    }
}
