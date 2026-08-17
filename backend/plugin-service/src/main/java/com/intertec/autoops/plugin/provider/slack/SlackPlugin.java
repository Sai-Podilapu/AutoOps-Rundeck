package com.intertec.autoops.plugin.provider.slack;

import com.intertec.autoops.plugin.provider.support.OutboundHttp;
import com.intertec.autoops.plugin.spi.ConfigField;
import com.intertec.autoops.plugin.spi.DeliveryResult;
import com.intertec.autoops.plugin.spi.NotificationMessage;
import com.intertec.autoops.plugin.spi.NotificationPlugin;
import com.intertec.autoops.plugin.spi.PluginContext;
import com.intertec.autoops.plugin.spi.PluginDescriptor;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Slack via an Incoming Webhook.
 *
 * <p>Chosen over a bot token deliberately: a webhook is scoped to exactly one
 * channel the tenant picked at creation time, so the worst a leaked AutoOps
 * database can do is post noise into that one channel. A bot token would carry
 * whatever scopes the workspace admin granted, across every channel.
 *
 * <p>The URL itself is the credential — anyone holding it can post as the
 * integration — which is why it is a {@link ConfigField.Type#SECRET} and is
 * encrypted at rest like a password.
 */
@Component
public class SlackPlugin implements NotificationPlugin {

    static final String WEBHOOK_URL = "webhookUrl";
    static final String USERNAME = "username";
    static final String ICON_EMOJI = "iconEmoji";

    /** Slack's attachment colour bar — the fastest signal in a busy channel. */
    private static final String GREEN = "#2eb67d";
    private static final String AMBER = "#ecb22e";
    private static final String RED = "#e01e5a";

    private final OutboundHttp http;

    public SlackPlugin(OutboundHttp http) {
        this.http = http;
    }

    @Override
    public PluginDescriptor descriptor() {
        return new PluginDescriptor(
                "slack",
                "Slack",
                PluginDescriptor.Category.CHAT,
                "Post job and workflow events into a Slack channel.",
                "https://api.slack.com/messaging/webhooks",
                List.of(
                        ConfigField.secret(WEBHOOK_URL, "Incoming webhook URL", true,
                                        "Slack → Apps → Incoming Webhooks → Add to Workspace. "
                                                + "Pick the channel there; this URL only posts to it.")
                                .withPlaceholder("https://hooks.slack.com/services/T…/B…/…"),
                        ConfigField.text(USERNAME, "Override bot name", false,
                                "Leave blank to use the name configured in Slack."),
                        ConfigField.text(ICON_EMOJI, "Override icon emoji", false,
                                "For example :rotating_light: — leave blank to use Slack's.")));
    }

    @Override
    public DeliveryResult send(PluginContext context, NotificationMessage message) {
        return http.postJson(context.require(WEBHOOK_URL), payload(context, message));
    }

    /**
     * Slack offers no no-op ping for webhooks: a webhook either posts a message
     * or it does not exist. So a connection test genuinely posts, and says so —
     * a "Test connection" that quietly proved nothing would be worse than none.
     */
    @Override
    public DeliveryResult verify(PluginContext context) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("text", "AutoOps is connected. This is a test message from the "
                + "\"" + context.displayName() + "\" integration — no job or workflow ran.");
        applyIdentity(context, body);
        return http.postJson(context.require(WEBHOOK_URL), body);
    }

    private Map<String, Object> payload(PluginContext context, NotificationMessage message) {
        Map<String, Object> attachment = new LinkedHashMap<>();
        attachment.put("color", colorFor(message));
        attachment.put("blocks", blocks(message));
        attachment.put("fallback", message.title());

        Map<String, Object> body = new LinkedHashMap<>();
        // Plain text drives the mobile push preview and the notification list;
        // without it a blocks-only message pushes as "sent an attachment".
        body.put("text", message.title());
        body.put("attachments", List.of(attachment));
        applyIdentity(context, body);
        return body;
    }

    private void applyIdentity(PluginContext context, Map<String, Object> body) {
        String username = context.optional(USERNAME, null);
        if (username != null) {
            body.put("username", username);
        }
        String icon = context.optional(ICON_EMOJI, null);
        if (icon != null) {
            body.put("icon_emoji", icon);
        }
    }

    private List<Map<String, Object>> blocks(NotificationMessage message) {
        List<Map<String, Object>> blocks = new ArrayList<>();
        blocks.add(section(mrkdwn("*" + escape(message.title()) + "*")));

        List<Map<String, Object>> facts = new ArrayList<>();
        if (message.projectName() != null) {
            facts.add(mrkdwn("*Project*\n" + escape(message.projectName())));
        }
        if (message.triggeredBy() != null) {
            facts.add(mrkdwn("*Triggered by*\n" + escape(message.triggeredBy())));
        }
        if (!message.durationText().isEmpty()) {
            facts.add(mrkdwn("*Duration*\n" + message.durationText()));
        }
        if (message.runId() != null) {
            facts.add(mrkdwn("*Run*\n#" + message.runId()));
        }
        if (!facts.isEmpty()) {
            Map<String, Object> fieldsSection = new LinkedHashMap<>();
            fieldsSection.put("type", "section");
            // Slack hard-caps a section at 10 fields and drops the whole block
            // if you exceed it.
            fieldsSection.put("fields", facts.size() > 10 ? facts.subList(0, 10) : facts);
            blocks.add(fieldsSection);
        }

        if (message.detail() != null && !message.detail().isBlank()) {
            blocks.add(section(mrkdwn("```" + escape(truncate(message.detail(), 2500)) + "```")));
        }

        if (message.hasConsoleUrl()) {
            Map<String, Object> button = new LinkedHashMap<>();
            button.put("type", "button");
            button.put("text", Map.of("type", "plain_text", "text", "Open in AutoOps"));
            button.put("url", message.consoleUrl());
            blocks.add(Map.of("type", "actions", "elements", List.of(button)));
        }

        blocks.add(Map.of("type", "context", "elements",
                List.of(mrkdwn(message.occurredAt().toString()))));
        return blocks;
    }

    private String colorFor(NotificationMessage message) {
        return switch (message.severity()) {
            case INFO -> GREEN;
            case WARNING -> AMBER;
            case CRITICAL -> RED;
        };
    }

    private static Map<String, Object> section(Map<String, Object> text) {
        return Map.of("type", "section", "text", text);
    }

    private static Map<String, Object> mrkdwn(String text) {
        return Map.of("type", "mrkdwn", "text", text);
    }

    /**
     * Slack's three control characters. A job named {@code <build>} would
     * otherwise be swallowed as a malformed link.
     */
    private static String escape(String value) {
        return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }

    private static String truncate(String value, int max) {
        return value.length() <= max ? value : value.substring(0, max) + "\n… truncated";
    }
}
