package com.intertec.autoops.rundeck.web.dto;

import java.util.List;
import java.util.Map;

/**
 * The normalized shapes the console renders, and the boundary where Rundeck's
 * wire format stops.
 *
 * <p><strong>Why normalize at all</strong>, rather than relay Rundeck's JSON
 * untouched: its payloads differ across API versions and across OSS vs
 * Enterprise, so a console reading them directly would be coupled to whichever
 * server the first customer happened to run. These records name the fields
 * AutoOps actually needs, and each carries {@code raw} — the untouched map — so
 * a field we did not anticipate is still reachable without a redeploy.
 *
 * <p>Every view is READ-ONLY. Nothing here is persisted; these are built fresh
 * from a live call on every request, because Rundeck's own console is a peer
 * writer and any copy we kept would start lying immediately.
 */
public final class RundeckViews {

    private RundeckViews() {
    }

    /** A Rundeck project (its unit of grouping, unrelated to an AutoOps project). */
    public record ProjectView(String name, String description, String url) {
    }

    /** One job in a project listing. */
    public record JobView(
            String id,
            String name,
            String group,
            String project,
            String description,
            String href,
            Boolean scheduled,
            Boolean scheduleEnabled,
            Boolean enabled,
            Long averageDuration) {
    }

    /**
     * A job option, which is what the run form is built from.
     *
     * <p>{@code secure} and {@code valueExposed} together decide how the field
     * is rendered and whether the value may ever be stored. A secure option is
     * masked; a secure option that is NOT value-exposed (Rundeck's "Secure
     * Remote Authentication") is used only by node executors and never reaches
     * a script, so it must not be echoed anywhere.
     */
    public record OptionView(
            String name,
            String label,
            String description,
            String defaultValue,
            boolean required,
            boolean secure,
            boolean valueExposed,
            boolean multivalued,
            boolean enforced,
            String delimiter,
            String regex,
            String type,
            List<String> values,
            String valuesUrl) {
    }

    /** A job with everything needed to render its run form. */
    public record JobDetailView(
            String id,
            String name,
            String group,
            String project,
            String description,
            String nodeFilter,
            boolean nodesSelectedByDefault,
            List<OptionView> options,
            Map<String, Object> raw) {
    }

    /** One execution, live from Rundeck. */
    public record ExecutionView(
            Long id,
            String status,
            String project,
            String jobId,
            String jobName,
            String user,
            String dateStarted,
            String dateEnded,
            String permalink,
            String description,
            String argstring,
            List<String> failedNodes,
            List<String> succeededNodes) {
    }

    /** One line of execution log. */
    public record LogEntry(
            String time,
            String level,
            String node,
            String step,
            String log) {
    }

    /**
     * A window of execution log plus the cursor for the next poll.
     *
     * <p>{@code offset} is opaque: it is whatever Rundeck told us, handed back
     * unchanged on the following request. Interpreting it here would couple this
     * service to a detail Rundeck is free to change.
     */
    public record LogView(
            boolean completed,
            boolean execCompleted,
            boolean hasFailedNodes,
            String execState,
            String offset,
            long lastModified,
            List<LogEntry> entries) {
    }

    /**
     * One node from the project's inventory.
     *
     * <p>This is the capability AutoOps has no native equivalent for, which is
     * the whole reason the integration is worth having: Rundeck knows the fleet
     * and can address a slice of it by tag.
     */
    public record NodeView(
            String name,
            String hostname,
            String username,
            String description,
            String osFamily,
            String osName,
            String osVersion,
            String osArch,
            List<String> tags,
            Map<String, Object> attributes) {
    }

    /** An AutoOps-side dispatch receipt. */
    public record DispatchView(
            Long id,
            Long connectionId,
            String connectionName,
            String rundeckProject,
            String jobId,
            String jobName,
            Long executionId,
            String nodeFilter,
            String status,
            String triggeredBy,
            String error,
            String createdAt) {
    }
}
