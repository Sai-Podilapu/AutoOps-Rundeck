package com.intertec.autoops.plugin.provider.support;

import com.intertec.autoops.plugin.spi.DeliveryResult;
import jakarta.mail.AuthenticationFailedException;
import jakarta.mail.internet.MimeMessage;
import org.springframework.mail.javamail.JavaMailSenderImpl;
import org.springframework.mail.javamail.MimeMessageHelper;
import org.springframework.stereotype.Component;

import java.io.UnsupportedEncodingException;
import java.time.Duration;
import java.util.List;
import java.util.Properties;

/**
 * The SMTP half of the email plugins. Gmail and Outlook differ only in host,
 * port and how the tenant obtains a password, so the transport lives here once.
 *
 * <p>A sender is built per call rather than cached. Caching would mean holding
 * a decrypted SMTP password in a long-lived bean, and pooling connections to a
 * provider that closes idle sockets aggressively buys nothing.
 *
 * <p>STARTTLS is required, never merely enabled: with {@code
 * starttls.required=false}, a downgrade leaves the password to travel in clear
 * text and the send still reports success.
 */
@Component
public class SmtpSender {

    private final Duration connectTimeout;
    private final Duration readTimeout;

    public SmtpSender() {
        // SMTP handshakes are chattier than an HTTP POST; these are separate
        // from the webhook timeouts on purpose.
        this(Duration.ofSeconds(10), Duration.ofSeconds(20));
    }

    SmtpSender(Duration connectTimeout, Duration readTimeout) {
        this.connectTimeout = connectTimeout;
        this.readTimeout = readTimeout;
    }

    /** Proves the credentials by opening an authenticated session — sends nothing. */
    public DeliveryResult verify(SmtpSettings settings) {
        try {
            build(settings).testConnection();
            return DeliveryResult.success(0, "Signed in to " + settings.host()
                    + " as " + settings.username() + ". No email was sent.");
        } catch (Exception ex) {
            return classify(ex, settings);
        }
    }

    public DeliveryResult send(SmtpSettings settings, EmailContent content) {
        try {
            JavaMailSenderImpl sender = build(settings);
            MimeMessage mime = sender.createMimeMessage();
            MimeMessageHelper helper = new MimeMessageHelper(mime, true, "UTF-8");
            if (settings.fromName() != null && !settings.fromName().isBlank()) {
                helper.setFrom(settings.from(), settings.fromName());
            } else {
                helper.setFrom(settings.from());
            }
            helper.setTo(content.to().toArray(new String[0]));
            helper.setSubject(content.subject());
            // Both parts: the text alternative is what pagers, watches and
            // plain-text clients actually show.
            helper.setText(content.text(), content.html());
            sender.send(mime);
            return DeliveryResult.success(0, "Sent to " + String.join(", ", content.to()));
        } catch (Exception ex) {
            return classify(ex, settings);
        }
    }

    private JavaMailSenderImpl build(SmtpSettings settings) {
        JavaMailSenderImpl sender = new JavaMailSenderImpl();
        sender.setHost(settings.host());
        sender.setPort(settings.port());
        sender.setUsername(settings.username());
        sender.setPassword(settings.password());
        sender.setDefaultEncoding("UTF-8");

        Properties props = sender.getJavaMailProperties();
        props.put("mail.transport.protocol", "smtp");
        props.put("mail.smtp.auth", "true");
        if (settings.port() == 465) {
            // Implicit TLS: the socket is wrapped before the greeting.
            props.put("mail.smtp.ssl.enable", "true");
        } else {
            props.put("mail.smtp.starttls.enable", "true");
            props.put("mail.smtp.starttls.required", "true");
        }
        // Verify the certificate against the host we meant to reach; without
        // this an intercepted connection is indistinguishable from a good one.
        props.put("mail.smtp.ssl.checkserveridentity", "true");
        props.put("mail.smtp.connectiontimeout", String.valueOf(connectTimeout.toMillis()));
        props.put("mail.smtp.timeout", String.valueOf(readTimeout.toMillis()));
        props.put("mail.smtp.writetimeout", String.valueOf(readTimeout.toMillis()));
        return sender;
    }

    /**
     * Bad credentials are permanent and must park the channel; a refused or
     * timed-out socket is worth retrying. Retrying an auth failure against
     * Gmail is how a tenant's account gets locked.
     */
    private DeliveryResult classify(Exception ex, SmtpSettings settings) {
        Throwable root = rootCause(ex);
        if (root instanceof AuthenticationFailedException) {
            return DeliveryResult.failure(settings.authFailureHint());
        }
        if (root instanceof UnsupportedEncodingException) {
            return DeliveryResult.failure("Invalid sender name: " + root.getMessage());
        }
        String message = root.getMessage() == null ? root.toString() : root.getMessage();
        if (message.contains("535") || message.contains("534") || message.contains("530")) {
            // Providers report auth problems as SMTP codes inside a generic
            // MessagingException as often as they throw the typed exception.
            return DeliveryResult.failure(settings.authFailureHint() + " (" + message + ")");
        }
        if (message.contains("550") || message.contains("553") || message.contains("554")) {
            return DeliveryResult.failure("The server rejected the message: " + message);
        }
        return DeliveryResult.retryable(root.getClass().getSimpleName() + ": " + message);
    }

    private static Throwable rootCause(Throwable ex) {
        Throwable current = ex;
        while (current.getCause() != null && current.getCause() != current) {
            current = current.getCause();
        }
        return current;
    }

    /** Everything needed to open one authenticated SMTP session. */
    public record SmtpSettings(
            String host,
            int port,
            String username,
            String password,
            String from,
            String fromName,
            /** Provider-specific wording for a rejected sign-in. */
            String authFailureHint) {
    }

    /** One rendered message, ready to send. */
    public record EmailContent(List<String> to, String subject, String html, String text) {
    }
}
