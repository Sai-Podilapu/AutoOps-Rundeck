package com.intertec.autoops.plugin.provider.github;

import com.intertec.autoops.plugin.provider.support.OutboundHttp;
import com.intertec.autoops.plugin.spi.ConfigField;
import com.intertec.autoops.plugin.spi.DeliveryResult;
import com.intertec.autoops.plugin.spi.NotificationMessage;
import com.intertec.autoops.plugin.spi.NotificationPlugin;
import com.intertec.autoops.plugin.spi.PluginContext;
import com.intertec.autoops.plugin.spi.PluginDescriptor;
import org.springframework.http.HttpHeaders;
import org.springframework.stereotype.Component;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

/**
 * GitHub — opens an issue in a repository when something happens to a job or
 * workflow.
 *
 * <p>Unlike the chat channels this one creates durable, assignable work, so it
 * is meant to be bound to failure events only. A rule that points STARTED at
 * this plugin will open an issue on every single run; the descriptor says so,
 * and {@code NotificationRuleService} warns when a rule does it.
 *
 * <p>Uses a fine-grained PAT with Issues:write on one repository. A classic
 * token with {@code repo} scope also works but grants far more than this needs.
 */
@Component
public class GitHubPlugin implements NotificationPlugin {

    static final String TOKEN = "token";
    static final String REPOSITORY = "repository";
    static final String LABELS = "labels";
    static final String ASSIGNEES = "assignees";
    static final String API_BASE_URL = "apiBaseUrl";

    private static final String PUBLIC_API = "https://api.github.com";

    private final OutboundHttp http;

    public GitHubPlugin(OutboundHttp http) {
        this.http = http;
    }

    @Override
    public PluginDescriptor descriptor() {
        return new PluginDescriptor(
                "github",
                "GitHub",
                PluginDescriptor.Category.TICKETING,
                "Open a GitHub issue when a job or workflow event fires. "
                        + "Best bound to failure events — one issue is created per event.",
                "https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens",
                List.of(
                        ConfigField.secret(TOKEN, "Access token", true,
                                        "A fine-grained personal access token with "
                                                + "Issues: Read and write on this repository.")
                                .withPlaceholder("github_pat_…"),
                        ConfigField.text(REPOSITORY, "Repository", true,
                                        "owner/repo — the repository issues are opened in.")
                                .withPlaceholder("intertec/autoops-runbooks"),
                        ConfigField.text(LABELS, "Labels", false,
                                "Comma-separated labels applied to every issue, e.g. incident,autoops"),
                        ConfigField.text(ASSIGNEES, "Assignees", false,
                                "Comma-separated GitHub usernames to assign."),
                        ConfigField.url(API_BASE_URL, "API base URL", false,
                                        "Only for GitHub Enterprise Server. Leave blank for github.com.")
                                .withPlaceholder(PUBLIC_API)));
    }

    @Override
    public DeliveryResult send(PluginContext context, NotificationMessage message) {
        String repository = normalizeRepository(context.require(REPOSITORY));
        Map<String, Object> issue = new LinkedHashMap<>();
        issue.put("title", message.title());
        issue.put("body", body(message));
        List<String> labels = csv(context.optional(LABELS, ""));
        if (!labels.isEmpty()) {
            issue.put("labels", labels);
        }
        List<String> assignees = csv(context.optional(ASSIGNEES, ""));
        if (!assignees.isEmpty()) {
            issue.put("assignees", assignees);
        }
        return http.postJson(apiBase(context) + "/repos/" + repository + "/issues",
                issue, headers(context));
    }

    /**
     * Reads the repository rather than writing to it — a test must not leave a
     * stray issue behind. A 200 here proves the token is valid, unexpired and
     * scoped to this repo, which is everything that can fail at send time
     * except the Issues:write bit itself.
     */
    @Override
    public DeliveryResult verify(PluginContext context) {
        String repository = normalizeRepository(context.require(REPOSITORY));
        DeliveryResult result = http.get(apiBase(context) + "/repos/" + repository,
                headers(context));
        if (result.ok()) {
            return DeliveryResult.success(200, "Repository " + repository + " is reachable.");
        }
        // GitHub answers 404 rather than 403 for a repo the token cannot see,
        // so "not found" and "no permission" are the same response.
        if (result.statusCode() != null && result.statusCode() == 404) {
            return DeliveryResult.failure(404,
                    "GitHub cannot see " + repository + " — check the name, and that the "
                            + "token grants access to this repository.");
        }
        if (result.statusCode() != null && result.statusCode() == 401) {
            return DeliveryResult.failure(401, "GitHub rejected the token.");
        }
        return result;
    }

    private String body(NotificationMessage message) {
        StringBuilder body = new StringBuilder();
        body.append("**").append(message.targetLabel()).append("** `")
                .append(message.targetName()).append("` — ")
                .append(message.event().name().toLowerCase()).append("\n\n");
        body.append("| | |\n|---|---|\n");
        row(body, "Project", message.projectName());
        row(body, "Triggered by", message.triggeredBy());
        row(body, "Run", message.runId() == null ? null : "#" + message.runId());
        row(body, "Duration", message.durationText().isEmpty() ? null : message.durationText());
        row(body, "When", message.occurredAt().toString());
        if (message.detail() != null && !message.detail().isBlank()) {
            body.append("\n```\n")
                    .append(truncate(message.detail(), 4000).replace("```", "``​`"))
                    .append("\n```\n");
        }
        if (message.hasConsoleUrl()) {
            body.append("\n[Open in AutoOps](").append(message.consoleUrl()).append(")\n");
        }
        body.append("\n<sub>Opened automatically by AutoOps.</sub>\n");
        return body.toString();
    }

    private static void row(StringBuilder body, String label, String value) {
        if (value != null && !value.isBlank()) {
            body.append("| **").append(label).append("** | ").append(value).append(" |\n");
        }
    }

    private Consumer<HttpHeaders> headers(PluginContext context) {
        String token = context.require(TOKEN);
        return headers -> {
            headers.setBearerAuth(token);
            headers.set(HttpHeaders.ACCEPT, "application/vnd.github+json");
            // Pinning the API version stops a future GitHub default from
            // silently changing the request or response shape under us.
            headers.set("X-GitHub-Api-Version", "2022-11-28");
            headers.set(HttpHeaders.USER_AGENT, "AutoOps");
        };
    }

    private String apiBase(PluginContext context) {
        String base = context.optional(API_BASE_URL, PUBLIC_API);
        return base.endsWith("/") ? base.substring(0, base.length() - 1) : base;
    }

    /** Accepts a full URL as well as owner/repo — people paste the browser bar. */
    private String normalizeRepository(String value) {
        String repository = value.trim();
        int githubCom = repository.indexOf("github.com/");
        if (githubCom >= 0) {
            repository = repository.substring(githubCom + "github.com/".length());
        }
        if (repository.endsWith(".git")) {
            repository = repository.substring(0, repository.length() - 4);
        }
        return repository.replaceAll("^/+", "").replaceAll("/+$", "");
    }

    private static List<String> csv(String value) {
        if (value == null || value.isBlank()) {
            return List.of();
        }
        return Arrays.stream(value.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .toList();
    }

    private static String truncate(String value, int max) {
        return value.length() <= max ? value : value.substring(0, max) + "\n… truncated";
    }
}
