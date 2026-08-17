package com.intertec.autoops.plugin.provider.support;

import com.intertec.autoops.plugin.spi.NotificationMessage;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;

/**
 * Renders a {@link NotificationMessage} into the HTML and plain-text bodies
 * the email plugins send. Shared so Gmail and Outlook produce identical mail —
 * a tenant who moves between them should not see the format change.
 *
 * <p>Deliberately inline-styled and table-free-ish: Outlook's Word rendering
 * engine ignores {@code <style>} blocks, flexbox and most of CSS, so anything
 * clever here would arrive as unstyled text for a large share of recipients.
 */
@Component
public class EmailRenderer {

    private static final String GREEN = "#1a7f5a";
    private static final String AMBER = "#a86a00";
    private static final String RED = "#c0243f";

    public String subject(NotificationMessage message) {
        // Severity marker first: it survives the truncation every mobile
        // client applies to a subject line.
        String marker = switch (message.severity()) {
            case INFO -> "";
            case WARNING -> "[Warning] ";
            case CRITICAL -> "[Alert] ";
        };
        return marker + message.title();
    }

    public String html(NotificationMessage message) {
        String accent = accent(message);
        StringBuilder html = new StringBuilder();
        html.append("<div style=\"font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,"
                + "sans-serif;font-size:14px;line-height:1.5;color:#1c2024;max-width:640px\">");
        html.append("<div style=\"border-left:4px solid ").append(accent)
                .append(";padding:4px 0 4px 14px;margin-bottom:18px\">")
                .append("<div style=\"font-size:17px;font-weight:600;color:").append(accent)
                .append("\">").append(escape(message.title())).append("</div></div>");

        html.append("<table cellpadding=\"0\" cellspacing=\"0\" border=\"0\" "
                + "style=\"border-collapse:collapse;margin-bottom:18px\">");
        for (String[] row : rows(message)) {
            html.append("<tr>")
                    .append("<td style=\"padding:3px 18px 3px 0;color:#6b7280;"
                            + "vertical-align:top;white-space:nowrap\">")
                    .append(escape(row[0])).append("</td>")
                    .append("<td style=\"padding:3px 0;vertical-align:top\">")
                    .append(escape(row[1])).append("</td>")
                    .append("</tr>");
        }
        html.append("</table>");

        if (message.detail() != null && !message.detail().isBlank()) {
            html.append("<pre style=\"background:#f4f5f7;border:1px solid #e3e5e8;"
                    + "border-radius:6px;padding:12px;overflow-x:auto;white-space:pre-wrap;"
                    + "word-break:break-word;font-size:12.5px;margin:0 0 18px\">")
                    .append(escape(truncate(message.detail(), 4000)))
                    .append("</pre>");
        }

        if (message.hasConsoleUrl()) {
            html.append("<a href=\"").append(escapeAttribute(message.consoleUrl()))
                    .append("\" style=\"display:inline-block;background:").append(accent)
                    .append(";color:#ffffff;text-decoration:none;padding:9px 18px;"
                            + "border-radius:6px;font-weight:600\">Open in AutoOps</a>");
        }

        html.append("<p style=\"color:#9aa1a9;font-size:12px;margin-top:26px\">"
                + "Sent by AutoOps because a notification rule matched this event.</p>");
        html.append("</div>");
        return html.toString();
    }

    public String text(NotificationMessage message) {
        StringBuilder text = new StringBuilder();
        text.append(message.title()).append("\n\n");
        for (String[] row : rows(message)) {
            text.append(row[0]).append(": ").append(row[1]).append('\n');
        }
        if (message.detail() != null && !message.detail().isBlank()) {
            text.append('\n').append(truncate(message.detail(), 4000)).append('\n');
        }
        if (message.hasConsoleUrl()) {
            text.append("\nOpen in AutoOps: ").append(message.consoleUrl()).append('\n');
        }
        text.append("\nSent by AutoOps because a notification rule matched this event.\n");
        return text.toString();
    }

    private List<String[]> rows(NotificationMessage message) {
        List<String[]> rows = new ArrayList<>();
        add(rows, message.targetLabel(), message.targetName());
        add(rows, "Project", message.projectName());
        add(rows, "Event", message.event().name());
        add(rows, "Triggered by", message.triggeredBy());
        add(rows, "Run", message.runId() == null ? null : "#" + message.runId());
        add(rows, "Duration", message.durationText().isEmpty() ? null : message.durationText());
        add(rows, "When", message.occurredAt().toString());
        return rows;
    }

    private static void add(List<String[]> rows, String label, String value) {
        if (value != null && !value.isBlank()) {
            rows.add(new String[]{label, value});
        }
    }

    private String accent(NotificationMessage message) {
        return switch (message.severity()) {
            case INFO -> GREEN;
            case WARNING -> AMBER;
            case CRITICAL -> RED;
        };
    }

    /**
     * Job names, error text and usernames all reach this from tenant input, and
     * the result is HTML delivered to a mailbox. Escaping is not optional.
     */
    private static String escape(String value) {
        return value.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;");
    }

    private static String escapeAttribute(String value) {
        return escape(value).replace("'", "&#39;");
    }

    private static String truncate(String value, int max) {
        return value.length() <= max ? value : value.substring(0, max) + "\n… truncated";
    }
}
