package com.intertec.autoops.plugin.provider.teams;

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
 * Microsoft Teams via a Workflows (Power Automate) webhook.
 *
 * <p>Targets Adaptive Cards, NOT the old {@code MessageCard} / Office 365
 * Connector format. Microsoft has retired O365 connectors, so a MessageCard
 * integration built today would stop delivering — the payload below is the
 * shape the "When a Teams webhook request is received" trigger expects.
 *
 * <p>Teams renders nothing but the card, so unlike Slack there is no plain
 * text fallback to set.
 */
@Component
public class TeamsPlugin implements NotificationPlugin {

    static final String WEBHOOK_URL = "webhookUrl";

    /** Adaptive Card container styles — Teams has no free-form colour. */
    private static final String GOOD = "good";
    private static final String WARNING = "warning";
    private static final String ATTENTION = "attention";

    private final OutboundHttp http;

    public TeamsPlugin(OutboundHttp http) {
        this.http = http;
    }

    @Override
    public PluginDescriptor descriptor() {
        return new PluginDescriptor(
                "microsoft-teams",
                "Microsoft Teams",
                PluginDescriptor.Category.CHAT,
                "Post job and workflow events into a Teams channel as an Adaptive Card.",
                "https://support.microsoft.com/en-us/office/create-incoming-webhooks-with-workflows-for-microsoft-teams-8ae491c7-0394-4861-ba59-055e33f75498",
                List.of(ConfigField.secret(WEBHOOK_URL, "Workflow webhook URL", true,
                                "In Teams: channel → ⋯ → Workflows → \"Post to a channel when a "
                                        + "webhook request is received\". Copy the URL it generates.")
                        .withPlaceholder("https://prod-…logic.azure.com:443/workflows/…")));
    }

    @Override
    public DeliveryResult send(PluginContext context, NotificationMessage message) {
        return http.postJson(context.require(WEBHOOK_URL), envelope(card(message)));
    }

    /** Like Slack, a Teams webhook can only be proven by posting through it. */
    @Override
    public DeliveryResult verify(PluginContext context) {
        List<Map<String, Object>> body = List.of(
                textBlock("AutoOps is connected", "Bolder", "Large", null),
                textBlock("Test message from the \"" + context.displayName()
                        + "\" integration — no job or workflow ran.", "Default", "Default", null));
        return http.postJson(context.require(WEBHOOK_URL), envelope(adaptiveCard(body, List.of())));
    }

    /**
     * Teams requires the card be wrapped as an attachment on a message.
     * A bare Adaptive Card posts 202 and then renders nothing at all.
     */
    private Map<String, Object> envelope(Map<String, Object> card) {
        Map<String, Object> attachment = new LinkedHashMap<>();
        attachment.put("contentType", "application/vnd.microsoft.card.adaptive");
        attachment.put("contentUrl", null);
        attachment.put("content", card);
        return Map.of("type", "message", "attachments", List.of(attachment));
    }

    private Map<String, Object> card(NotificationMessage message) {
        List<Map<String, Object>> body = new ArrayList<>();
        body.add(textBlock(message.title(), "Bolder", "Large", styleFor(message)));

        List<Map<String, Object>> facts = new ArrayList<>();
        addFact(facts, "Project", message.projectName());
        addFact(facts, "Triggered by", message.triggeredBy());
        addFact(facts, "Duration", message.durationText().isEmpty() ? null : message.durationText());
        addFact(facts, "Run", message.runId() == null ? null : "#" + message.runId());
        addFact(facts, "When", message.occurredAt().toString());
        if (!facts.isEmpty()) {
            body.add(Map.of("type", "FactSet", "facts", facts));
        }

        if (message.detail() != null && !message.detail().isBlank()) {
            Map<String, Object> detail = new LinkedHashMap<>();
            detail.put("type", "TextBlock");
            detail.put("text", truncate(message.detail(), 2500));
            detail.put("wrap", true);
            detail.put("fontType", "Monospace");
            detail.put("isSubtle", true);
            body.add(detail);
        }

        List<Map<String, Object>> actions = new ArrayList<>();
        if (message.hasConsoleUrl()) {
            actions.add(Map.of("type", "Action.OpenUrl", "title", "Open in AutoOps",
                    "url", message.consoleUrl()));
        }
        return adaptiveCard(body, actions);
    }

    private Map<String, Object> adaptiveCard(List<Map<String, Object>> body,
                                             List<Map<String, Object>> actions) {
        Map<String, Object> card = new LinkedHashMap<>();
        card.put("type", "AdaptiveCard");
        card.put("$schema", "http://adaptivecards.io/schemas/adaptive-card.json");
        // 1.4 is the highest the Teams webhook renderer supports; naming a
        // newer version makes it fall back to a blank card.
        card.put("version", "1.4");
        card.put("body", body);
        if (!actions.isEmpty()) {
            card.put("actions", actions);
        }
        return card;
    }

    private static void addFact(List<Map<String, Object>> facts, String title, String value) {
        if (value != null && !value.isBlank()) {
            facts.add(Map.of("title", title, "value", value));
        }
    }

    private static Map<String, Object> textBlock(String text, String weight, String size,
                                                 String color) {
        Map<String, Object> block = new LinkedHashMap<>();
        block.put("type", "TextBlock");
        block.put("text", text);
        block.put("weight", weight);
        block.put("size", size);
        block.put("wrap", true);
        if (color != null) {
            block.put("color", color);
        }
        return block;
    }

    private String styleFor(NotificationMessage message) {
        return switch (message.severity()) {
            case INFO -> GOOD;
            case WARNING -> WARNING;
            case CRITICAL -> ATTENTION;
        };
    }

    private static String truncate(String value, int max) {
        return value.length() <= max ? value : value.substring(0, max) + "\n… truncated";
    }
}
