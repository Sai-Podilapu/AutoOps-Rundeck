package com.intertec.autoops.plugin.provider.outlook;

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
 * Outlook / Microsoft 365 over SMTP.
 *
 * <p>Same reasoning as the Gmail plugin: there is no OAuth2 client
 * infrastructure in the platform, so Microsoft Graph {@code sendMail} is not
 * reachable without building a token store and refresh loop first.
 *
 * <p>One caveat the tenant must know, and {@code verify()} surfaces plainly:
 * Microsoft disables SMTP AUTH by default on new Microsoft 365 tenants. A
 * Global Admin has to enable it for the mailbox (or org-wide) before this can
 * sign in, and security defaults must be off or an exclusion granted. The host
 * is configurable so an on-premises Exchange or an SMTP relay can be used
 * instead.
 */
@Component
public class OutlookPlugin implements NotificationPlugin {

    static final String USERNAME = "username";
    static final String PASSWORD = "password";
    static final String RECIPIENTS = "recipients";
    static final String FROM_NAME = "fromName";
    static final String HOST = "host";
    static final String PORT = "port";

    private static final String DEFAULT_HOST = "smtp.office365.com";
    private static final int DEFAULT_PORT = 587;

    private static final String AUTH_HINT =
            "Microsoft rejected the sign-in. SMTP AUTH is disabled by default on "
                    + "Microsoft 365 — a Global Admin must enable it for this mailbox. "
                    + "If the account has MFA, an app password is required too.";

    private final SmtpSender smtp;
    private final EmailRenderer renderer;

    public OutlookPlugin(SmtpSender smtp, EmailRenderer renderer) {
        this.smtp = smtp;
        this.renderer = renderer;
    }

    @Override
    public PluginDescriptor descriptor() {
        return new PluginDescriptor(
                "outlook",
                "Outlook",
                PluginDescriptor.Category.EMAIL,
                "Email job and workflow events from an Outlook or Microsoft 365 mailbox.",
                "https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission",
                List.of(
                        ConfigField.email(USERNAME, "Mailbox address", true,
                                        "The mailbox notifications are sent from.")
                                .withPlaceholder("ops@yourcompany.com"),
                        ConfigField.secret(PASSWORD, "Password or app password", true,
                                "Use an app password if the account has MFA enabled."),
                        ConfigField.text(RECIPIENTS, "Send to", true,
                                        "Comma-separated recipient addresses.")
                                .withPlaceholder("oncall@yourcompany.com, sre@yourcompany.com"),
                        ConfigField.text(FROM_NAME, "Sender name", false,
                                "Display name on the email. Defaults to AutoOps."),
                        ConfigField.text(HOST, "SMTP host", false,
                                        "Only for on-premises Exchange or a relay. "
                                                + "Leave blank for Microsoft 365.")
                                .withPlaceholder(DEFAULT_HOST),
                        ConfigField.number(PORT, "SMTP port", false,
                                        "587 for STARTTLS, 465 for implicit TLS.")
                                .withPlaceholder(String.valueOf(DEFAULT_PORT))));
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
                context.optional(HOST, DEFAULT_HOST),
                context.optionalInt(PORT, DEFAULT_PORT),
                username,
                context.require(PASSWORD),
                // Exchange Online refuses to submit mail whose From differs
                // from the authenticated mailbox without a Send As grant.
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
