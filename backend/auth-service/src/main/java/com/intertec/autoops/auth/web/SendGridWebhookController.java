package com.intertec.autoops.auth.web;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.domain.OtpDeliveryStatus;
import com.intertec.autoops.auth.repo.OtpRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.Signature;
import java.security.spec.X509EncodedKeySpec;
import java.util.Base64;

/**
 * Optional SendGrid Event Webhook: updates otp_entries.delivery_status to
 * DELIVERED / BOUNCED / FAILED by sg_message_id.
 *
 * <p>Signatures are verified with the ECDSA public key from
 * {@code SENDGRID_WEBHOOK_PUBLIC_KEY} (signed payload = timestamp + raw body).
 * If no key is configured the webhook is disabled and returns 403.
 */
@RestController
@RequestMapping("/api/auth/webhooks")
public class SendGridWebhookController {

    private static final Logger log = LoggerFactory.getLogger(SendGridWebhookController.class);
    private static final String SIGNATURE_HEADER = "X-Twilio-Email-Event-Webhook-Signature";
    private static final String TIMESTAMP_HEADER = "X-Twilio-Email-Event-Webhook-Timestamp";

    private final AuthProperties properties;
    private final OtpRepository otpRepository;
    private final ObjectMapper objectMapper;

    public SendGridWebhookController(AuthProperties properties,
                                     OtpRepository otpRepository,
                                     ObjectMapper objectMapper) {
        this.properties = properties;
        this.otpRepository = otpRepository;
        this.objectMapper = objectMapper;
    }

    @PostMapping("/sendgrid")
    @Transactional
    public ResponseEntity<Void> handleEvents(@RequestBody String rawBody,
                                             @RequestHeader(value = SIGNATURE_HEADER, required = false) String signature,
                                             @RequestHeader(value = TIMESTAMP_HEADER, required = false) String timestamp) {
        String publicKey = properties.getSendgrid().getWebhookPublicKey();
        if (publicKey == null || publicKey.isBlank()) {
            return ResponseEntity.status(403).build(); // webhook disabled
        }
        if (signature == null || timestamp == null
                || !verifySignature(publicKey, timestamp + rawBody, signature)) {
            log.warn("Rejected SendGrid webhook call with missing/invalid signature");
            return ResponseEntity.status(403).build();
        }

        try {
            JsonNode events = objectMapper.readTree(rawBody);
            if (events.isArray()) {
                for (JsonNode event : events) {
                    applyEvent(event);
                }
            }
        } catch (Exception ex) {
            log.error("Failed to process SendGrid webhook payload: {}", ex.getMessage());
            return ResponseEntity.badRequest().build();
        }
        return ResponseEntity.ok().build();
    }

    private void applyEvent(JsonNode event) {
        String messageId = event.path("sg_message_id").asText(null);
        String eventType = event.path("event").asText("");
        if (messageId == null || messageId.isBlank()) {
            return;
        }
        // sg_message_id can carry a suffix after the first dot; the stored
        // X-Message-Id is the prefix.
        String normalizedId = messageId.contains(".")
                ? messageId.substring(0, messageId.indexOf('.'))
                : messageId;
        OtpDeliveryStatus newStatus = switch (eventType) {
            case "delivered" -> OtpDeliveryStatus.DELIVERED;
            case "bounce" -> OtpDeliveryStatus.BOUNCED;
            case "dropped", "deferred" -> OtpDeliveryStatus.FAILED;
            default -> null;
        };
        if (newStatus == null) {
            return;
        }
        otpRepository.findBySendgridMessageId(normalizedId).ifPresent(entry -> {
            entry.setDeliveryStatus(newStatus);
            otpRepository.save(entry);
        });
    }

    /** ECDSA (SHA256withECDSA) verification using standard JCA — no extra deps. */
    private boolean verifySignature(String base64PublicKey, String signedPayload, String base64Signature) {
        try {
            byte[] keyBytes = Base64.getDecoder().decode(base64PublicKey);
            PublicKey publicKey = KeyFactory.getInstance("EC")
                    .generatePublic(new X509EncodedKeySpec(keyBytes));
            Signature verifier = Signature.getInstance("SHA256withECDSA");
            verifier.initVerify(publicKey);
            verifier.update(signedPayload.getBytes(StandardCharsets.UTF_8));
            return verifier.verify(Base64.getDecoder().decode(base64Signature));
        } catch (Exception ex) {
            log.warn("SendGrid webhook signature verification error: {}", ex.getMessage());
            return false;
        }
    }
}
