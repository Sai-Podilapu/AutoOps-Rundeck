package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.domain.AuditEventType;
import com.intertec.autoops.auth.domain.OtpDeliveryStatus;
import com.intertec.autoops.auth.repo.OtpRepository;
import com.sendgrid.Method;
import com.sendgrid.Request;
import com.sendgrid.Response;
import com.sendgrid.SendGrid;
import com.sendgrid.helpers.mail.Mail;
import com.sendgrid.helpers.mail.objects.Content;
import com.sendgrid.helpers.mail.objects.Email;
import com.sendgrid.helpers.mail.objects.Personalization;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.event.TransactionPhase;
import org.springframework.transaction.event.TransactionalEventListener;

/**
 * Sends the OTP email via a SendGrid dynamic template AFTER the generating
 * transaction commits (so we never email a code that was rolled back).
 *
 * <p>One retry on failure; then FAIL-CLOSED: delivery_status=FAILED plus an
 * OTP_DELIVERY_FAILED audit event. On acceptance (2xx) the X-Message-Id
 * response header is stored for Event Webhook correlation.
 */
@Service
public class SendGridEmailService {

    private static final Logger log = LoggerFactory.getLogger(SendGridEmailService.class);
    private static final int MAX_SEND_ATTEMPTS = 2; // initial attempt + one retry

    private final SendGrid sendGrid;
    private final OtpRepository otpRepository;
    private final AuthProperties properties;
    private final AuditService auditService;

    public SendGridEmailService(SendGrid sendGrid,
                                OtpRepository otpRepository,
                                AuthProperties properties,
                                AuditService auditService) {
        this.sendGrid = sendGrid;
        this.otpRepository = otpRepository;
        this.properties = properties;
        this.auditService = auditService;
    }

    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void onOtpGenerated(OtpEmailEvent event) {
        // Tracked explicitly rather than inferred from messageId: SendGrid can
        // accept a message (2xx) without returning an X-Message-Id header, and
        // a retry that succeeds after a failed first attempt leaves lastError
        // set. Inferring from those two would mark a DELIVERED code FAILED.
        boolean accepted = false;
        String messageId = null;
        String lastError = null;

        for (int attempt = 1; attempt <= MAX_SEND_ATTEMPTS; attempt++) {
            try {
                Response response = sendGrid.api(buildRequest(event));
                int status = response.getStatusCode();
                if (status >= 200 && status < 300) {
                    accepted = true;
                    messageId = response.getHeaders() != null
                            ? response.getHeaders().get("X-Message-Id")
                            : null;
                    break;
                }
                // The BODY carries SendGrid's actual reason ("does not match a
                // verified Sender Identity", "Maximum credits exceeded", ...).
                // Logging the bare status turns every misconfiguration into an
                // unexplained HTTP 403.
                lastError = "HTTP " + status + " " + describe(response.getBody());
                log.warn("SendGrid rejected OTP email (attempt {}/{}): {}",
                        attempt, MAX_SEND_ATTEMPTS, lastError);
                if (!retryable(status)) {
                    // 4xx is a configuration/credential problem: an immediate
                    // identical retry cannot succeed and just burns an API call.
                    break;
                }
            } catch (Exception ex) {
                lastError = ex.getMessage();
                log.warn("SendGrid call failed (attempt {}/{}): {}",
                        attempt, MAX_SEND_ATTEMPTS, lastError);
            }
        }

        if (accepted) {
            markSent(event, messageId);
        } else {
            markFailed(event, lastError == null ? "no response" : lastError);
        }
    }

    /** 429 and 5xx are transient; every other rejection needs a config change. */
    private static boolean retryable(int status) {
        return status == 429 || status >= 500;
    }

    /** Response body, collapsed and clipped to fit auth_audit_log.detail. */
    private static String describe(String body) {
        if (body == null || body.isBlank()) {
            return "(no response body)";
        }
        String flat = body.replaceAll("\\s+", " ").trim();
        return flat.length() > 500 ? flat.substring(0, 500) + "…" : flat;
    }

    private Request buildRequest(OtpEmailEvent event) throws java.io.IOException {
        Mail mail = new Mail();
        mail.setFrom(new Email(properties.getSendgrid().getFromEmail(), "AutoOps"));

        Personalization personalization = new Personalization();
        personalization.addTo(new Email(event.email()));
        String templateId = properties.getSendgrid().getOtpTemplateId();
        long ttlMinutes = properties.getOtp().getTtl().toMinutes();
        if (usableTemplate(templateId)) {
            mail.setTemplateId(templateId);
            personalization.addDynamicTemplateData("otp", event.otp());
            personalization.addDynamicTemplateData("ttlMinutes", ttlMinutes);
        } else {
            // Plain-text fallback: an API key + verified sender is enough —
            // no SendGrid dynamic template required to go live.
            mail.setSubject("Your AutoOps verification code");
            mail.addContent(new Content("text/plain",
                    "Your AutoOps verification code is " + event.otp()
                            + ". It expires in " + ttlMinutes + " minutes.\n\n"
                            + "If you didn't request this code, you can ignore this email."));
        }
        mail.addPersonalization(personalization);

        Request request = new Request();
        request.setMethod(Method.POST);
        request.setEndpoint("mail/send");
        request.setBody(mail.build());
        return request;
    }

    /**
     * Best-effort team invitation ("sign in with a one-time code") — an email
     * failure must never break onboarding; the member can still log in.
     */
    public void sendInvite(String email, String workspaceName) {
        try {
            Mail mail = new Mail();
            mail.setFrom(new Email(properties.getSendgrid().getFromEmail(), "AutoOps"));
            mail.setSubject("You've been added to " + workspaceName + " on AutoOps");
            mail.addContent(new Content("text/plain",
                    "You've been added to the \"" + workspaceName + "\" workspace on AutoOps.\n\n"
                            + "Sign in with this email address using a one-time code — "
                            + "no password needed."));
            Personalization personalization = new Personalization();
            personalization.addTo(new Email(email));
            mail.addPersonalization(personalization);

            Request request = new Request();
            request.setMethod(Method.POST);
            request.setEndpoint("mail/send");
            request.setBody(mail.build());
            Response response = sendGrid.api(request);
            if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
                log.warn("SendGrid rejected invite email: HTTP {} {}",
                        response.getStatusCode(), describe(response.getBody()));
            }
        } catch (Exception ex) {
            log.warn("Invite email failed: {}", ex.getMessage());
        }
    }

    private static boolean usableTemplate(String templateId) {
        return templateId != null && !templateId.isBlank() && !"REPLACE_ME".equals(templateId);
    }

    private void markSent(OtpEmailEvent event, String messageId) {
        otpRepository.findById(event.otpEntryId()).ifPresent(entry -> {
            entry.setDeliveryStatus(OtpDeliveryStatus.SENT);
            entry.setSendgridMessageId(messageId);
            otpRepository.save(entry);
        });
        auditService.record(AuditEventType.OTP_SENT, null, event.email(), event.tenantId(),
                null, event.ipAddress(), null, null);
    }

    private void markFailed(OtpEmailEvent event, String reason) {
        otpRepository.findById(event.otpEntryId()).ifPresent(entry -> {
            entry.setDeliveryStatus(OtpDeliveryStatus.FAILED);
            otpRepository.save(entry);
        });
        auditService.record(AuditEventType.OTP_DELIVERY_FAILED, null, event.email(),
                event.tenantId(), null, event.ipAddress(), null, reason);
    }
}
