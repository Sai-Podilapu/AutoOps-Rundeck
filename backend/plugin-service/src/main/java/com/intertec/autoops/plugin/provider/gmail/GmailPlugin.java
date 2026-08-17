package com.intertec.autoops.plugin.provider.gmail;

import com.intertec.autoops.plugin.provider.support.EmailRenderer;
import com.intertec.autoops.plugin.provider.support.SmtpSender;
import com.intertec.autoops.plugin.spi.ConfigField;
import com.intertec.autoops.plugin.spi.DeliveryResult;
import com.intertec.autoops.plugin.spi.NotificationMessage;
import com.intertec.autoops.plugin.spi.NotificationPlugin;
import com.intertec.autoops.plugin.spi.PluginContext;
import com.intertec.autoops.plugin.spi.PluginDescriptor;
import org.springframework.stereotype.Component;

import java.util.Arrays;
import java.util.List;

/**
 * Gmail / Google Workspace over SMTP.
 *
 * <p>SMTP with an App Password, not the Gmail API: AutoOps has no OAuth2
 * client infrastructure at all — no {@code ClientRegistration}, no third-party
 * token store, no refresh loop — so an OAuth path would be a large piece of
 * greenfield work in its own right. An App Password is a real, first-class
 * Google credential that works today and that the tenant can revoke
 * independently of their account password.
 *
 * <p>It does require 2-Step Verification on the account, and Workspace admins
 * can disable App Passwords org-wide. When that is the case the tenant sees
 * the sign-in failure from {@code verify()} rather than silence.
 */
@Component
public class GmailPlugin implements NotificationPlugin {

    static final String USERNAME = "username";
    static final String APP_PASSWORD = "appPassword";
    static final String RECIPIENTS = "recipients";
    static final String FROM_NAME = "fromName";

    private static final String HOST = "smtp.gmail.com";
    private static final int PORT = 587;

    private static final String AUTH_HINT =
            "Google rejected the sign-in. Use a 16-character App Password "
                    + "(myaccount.google.com/apppasswords), not the account password — "
                    + "and confirm 2-Step Verification is on.";

    private final SmtpSender smtp;
    private final EmailRenderer renderer;

    public GmailPlugin(SmtpSender smtp, EmailRenderer renderer) {
        this.smtp = smtp;
        this.renderer = renderer;
    }

    @Override
    public PluginDescriptor descriptor() {
        return new PluginDescriptor(
                "gmail",
                "Gmail",
                PluginDescriptor.Category.EMAIL,
                "Email job and workflow events from a Gmail or Google Workspace account.",
                "https://support.google.com/accounts/answer/185833",
                List.of(
                        ConfigField.email(USERNAME, "Gmail address", true,
                                        "The account the notifications are sent from.")
                                .withPlaceholder("ops@yourcompany.com"),
                        ConfigField.secret(APP_PASSWORD, "App password", true,
                                        "16 characters from myaccount.google.com/apppasswords. "
                                                + "Requires 2-Step Verification.")
                                .withPlaceholder("abcd efgh ijkl mnop"),
                        ConfigField.text(RECIPIENTS, "Send to", true,
                                        "Comma-separated recipient addresses.")
                                .withPlaceholder("oncall@yourcompany.com, sre@yourcompany.com"),
                        ConfigField.text(FROM_NAME, "Sender name", false,
                                "Display name on the email. Defaults to AutoOps.")));
    }

    @Override
    public DeliveryResult send(PluginContext context, NotificationMessage message) {
        List<String> recipients = recipients(context);
        if (recipients.isEmpty()) {
            return DeliveryResult.failure("No recipients are configured.");
        }
        return smtp.send(settings(context), new SmtpSender.EmailContent(
                recipients,
                renderer.subject(message),
                renderer.html(message),
                renderer.text(message)));
    }

    /** Opens an authenticated SMTP session and closes it — no email is sent. */
    @Override
    public DeliveryResult verify(PluginContext context) {
        if (recipients(context).isEmpty()) {
            return DeliveryResult.failure("No recipients are configured.");
        }
        return smtp.verify(settings(context));
    }

    private SmtpSender.SmtpSettings settings(PluginContext context) {
        String username = context.require(USERNAME);
        return new SmtpSender.SmtpSettings(
                HOST, PORT, username, context.require(APP_PASSWORD),
                // Gmail rewrites the From header to the authenticated account
                // unless the address is a verified alias, so sending as the
                // account itself is the only reliable choice.
                username,
                context.optional(FROM_NAME, "AutoOps"),
                AUTH_HINT);
    }

    private List<String> recipients(PluginContext context) {
        return Arrays.stream(context.optional(RECIPIENTS, "").split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .toList();
    }
}
