package com.intertec.autoops.rundeck.service;

import com.intertec.autoops.rundeck.web.dto.RundeckViews.ExecutionView;
import com.intertec.autoops.rundeck.web.dto.RundeckViews.JobDetailView;
import com.intertec.autoops.rundeck.web.dto.RundeckViews.JobView;
import com.intertec.autoops.rundeck.web.dto.RundeckViews.LogEntry;
import com.intertec.autoops.rundeck.web.dto.RundeckViews.LogView;
import com.intertec.autoops.rundeck.web.dto.RundeckViews.NodeView;
import com.intertec.autoops.rundeck.web.dto.RundeckViews.OptionView;
import com.intertec.autoops.rundeck.web.dto.RundeckViews.ProjectView;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Rundeck's wire format in, AutoOps' view records out.
 *
 * <p>Every accessor here is defensive on purpose. These maps come from a server
 * we do not control, running a version we did not choose: a field can be
 * absent, null, a string where a number was expected, or a single object where
 * a list was. None of those may become a 500 — a job list that renders with one
 * missing description is worth more than an error page, and a run form that
 * renders is worth more than a stack trace about a missing {@code enforced}
 * flag.
 *
 * <p>The one place this leniency stops is {@link #options}: an option that
 * cannot be read is not silently dropped, because a run form missing a REQUIRED
 * field would dispatch a job with a value the operator never saw.
 */
@Component
public class RundeckMapper {

    public List<ProjectView> projects(List<Map<String, Object>> rows) {
        List<ProjectView> out = new ArrayList<>();
        for (Map<String, Object> row : safe(rows)) {
            out.add(new ProjectView(str(row.get("name")), str(row.get("description")),
                    str(row.get("url"))));
        }
        return out;
    }

    public List<JobView> jobs(List<Map<String, Object>> rows) {
        List<JobView> out = new ArrayList<>();
        for (Map<String, Object> row : safe(rows)) {
            out.add(new JobView(
                    str(row.get("id")),
                    str(row.get("name")),
                    str(row.get("group")),
                    str(row.get("project")),
                    str(row.get("description")),
                    str(row.get("href")),
                    bool(row.get("scheduled")),
                    bool(row.get("scheduleEnabled")),
                    bool(row.get("enabled")),
                    lng(row.get("averageDuration"))));
        }
        return out;
    }

    /**
     * A job definition (from the single-job export) into the shape the run form
     * needs.
     *
     * <p>The node filter lives at {@code nodefilters.filter}; when it is absent
     * the job is a workflow-step-only job that dispatches nowhere, and the
     * console renders no node selector rather than an empty one.
     */
    public JobDetailView jobDetail(Map<String, Object> definition) {
        Map<String, Object> nodeFilters = map(definition.get("nodefilters"));
        return new JobDetailView(
                str(definition.get("id")),
                str(definition.get("name")),
                str(definition.get("group")),
                str(definition.get("project")),
                str(definition.get("description")),
                str(nodeFilters.get("filter")),
                Boolean.TRUE.equals(definition.get("nodesSelectedByDefault")),
                options(definition.get("options")),
                definition);
    }

    /**
     * Job options.
     *
     * <p>Rundeck emits these two different ways depending on export format and
     * version: a LIST of option objects (each with its own {@code name}), or a
     * MAP keyed by option name. Both are handled — a run form that silently
     * showed no fields because the server used the other shape would submit a
     * job with every option left at its default, which is a correctness bug
     * wearing a cosmetic disguise.
     */
    @SuppressWarnings("unchecked")
    public List<OptionView> options(Object raw) {
        List<OptionView> out = new ArrayList<>();
        if (raw instanceof List<?> list) {
            for (Object item : list) {
                if (item instanceof Map<?, ?> m) {
                    out.add(option(str(((Map<String, Object>) m).get("name")),
                            (Map<String, Object>) m));
                }
            }
        } else if (raw instanceof Map<?, ?> byName) {
            for (Map.Entry<?, ?> entry : byName.entrySet()) {
                if (entry.getValue() instanceof Map<?, ?> m) {
                    out.add(option(str(entry.getKey()), (Map<String, Object>) m));
                }
            }
        }
        return out;
    }

    private OptionView option(String name, Map<String, Object> o) {
        // valueExposed defaults TRUE for a plain option and is only meaningful
        // when secure is set. A secure option with valueExposed=false is
        // Rundeck's "Secure Remote Authentication": the value reaches node
        // executors and never a script, so it must never be echoed back.
        boolean secure = Boolean.TRUE.equals(o.get("secure"));
        boolean exposed = o.get("valueExposed") == null
                ? !secure
                : Boolean.TRUE.equals(o.get("valueExposed"));
        return new OptionView(
                name,
                str(o.get("label")),
                str(o.get("description")),
                str(o.get("value")),
                Boolean.TRUE.equals(o.get("required")),
                secure,
                exposed,
                Boolean.TRUE.equals(o.get("multivalued")),
                Boolean.TRUE.equals(o.get("enforced")),
                str(o.get("delimiter")),
                str(o.get("regex")),
                str(o.get("type")),
                strings(o.get("values")),
                str(o.get("valuesUrl")));
    }

    /**
     * One execution — from either of the two shapes Rundeck returns.
     *
     * <p>{@code /job/{id}/run} answers with the execution object at the top
     * level. The AD-HOC endpoints ({@code /run/command}, {@code /run/script})
     * answer with {@code {"message": "...", "execution": {...}}} instead.
     * Handling only the flat one produced a dispatch that succeeded upstream
     * and reported "no execution id" here — the step ran, and AutoOps could
     * neither wait for it nor abort it.
     */
    public ExecutionView execution(Map<String, Object> body) {
        Map<String, Object> row = body.get("execution") instanceof Map
                ? map(body.get("execution")) : body;
        Map<String, Object> job = map(row.get("job"));
        return new ExecutionView(
                lng(row.get("id")),
                str(row.get("status")),
                str(row.get("project")),
                str(job.get("id")),
                str(job.get("name")),
                str(row.get("user")),
                str(row.get("date-started") != null ? nested(row.get("date-started")) : null),
                str(row.get("date-ended") != null ? nested(row.get("date-ended")) : null),
                str(row.get("permalink")),
                str(row.get("description")),
                str(row.get("argstring")),
                strings(row.get("failedNodes")),
                strings(row.get("successfulNodes")));
    }

    public List<ExecutionView> executions(Map<String, Object> body) {
        List<ExecutionView> out = new ArrayList<>();
        Object rows = body.get("executions");
        if (rows instanceof List<?> list) {
            for (Object item : list) {
                if (item instanceof Map<?, ?> m) {
                    @SuppressWarnings("unchecked")
                    Map<String, Object> row = (Map<String, Object>) m;
                    out.add(execution(row));
                }
            }
        }
        return out;
    }

    public LogView log(Map<String, Object> body) {
        List<LogEntry> entries = new ArrayList<>();
        Object rows = body.get("entries");
        if (rows instanceof List<?> list) {
            for (Object item : list) {
                if (item instanceof Map<?, ?> m) {
                    @SuppressWarnings("unchecked")
                    Map<String, Object> entry = (Map<String, Object>) m;
                    entries.add(new LogEntry(
                            str(entry.get("absolute_time") != null
                                    ? entry.get("absolute_time") : entry.get("time")),
                            str(entry.get("level")),
                            str(entry.get("node")),
                            str(entry.get("stepctx")),
                            str(entry.get("log"))));
                }
            }
        }
        return new LogView(
                Boolean.TRUE.equals(body.get("completed")),
                Boolean.TRUE.equals(body.get("execCompleted")),
                Boolean.TRUE.equals(body.get("hasFailedNodes")),
                str(body.get("execState")),
                str(body.get("offset")),
                lng(body.get("lastModified")) == null ? 0L : lng(body.get("lastModified")),
                entries);
    }

    /**
     * The node inventory. Rundeck returns a map keyed by node NAME, whose
     * values carry the attributes — so the key is the identity and the body is
     * everything else.
     */
    @SuppressWarnings("unchecked")
    public List<NodeView> nodes(Map<String, Object> body) {
        List<NodeView> out = new ArrayList<>();
        for (Map.Entry<String, Object> entry : safe(body).entrySet()) {
            if (!(entry.getValue() instanceof Map<?, ?> value)) {
                continue;
            }
            Map<String, Object> node = (Map<String, Object>) value;
            out.add(new NodeView(
                    str(node.getOrDefault("nodename", entry.getKey())),
                    str(node.get("hostname")),
                    str(node.get("username")),
                    str(node.get("description")),
                    str(node.get("osFamily")),
                    str(node.get("osName")),
                    str(node.get("osVersion")),
                    str(node.get("osArch")),
                    tags(node.get("tags")),
                    attributes(node)));
        }
        out.sort((a, b) -> String.valueOf(a.name()).compareToIgnoreCase(String.valueOf(b.name())));
        return out;
    }

    /**
     * Rundeck sends tags as a comma-separated STRING in the JSON resource
     * format and as a list in some plugin sources. Both arrive here.
     */
    private static List<String> tags(Object raw) {
        if (raw instanceof List<?> list) {
            return list.stream().map(String::valueOf).map(String::trim)
                    .filter(s -> !s.isEmpty()).toList();
        }
        if (raw instanceof String s && !s.isBlank()) {
            return Arrays.stream(s.split(",")).map(String::trim)
                    .filter(v -> !v.isEmpty()).toList();
        }
        return List.of();
    }

    /** Everything that is not a field we named, kept so nothing is lost. */
    private static Map<String, Object> attributes(Map<String, Object> node) {
        Map<String, Object> out = new LinkedHashMap<>(node);
        out.keySet().removeAll(List.of("nodename", "hostname", "username", "description",
                "osFamily", "osName", "osVersion", "osArch", "tags"));
        return out;
    }

    // ---- lenient accessors -------------------------------------------------

    private static String str(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static Boolean bool(Object value) {
        if (value instanceof Boolean b) {
            return b;
        }
        return value == null ? null : Boolean.valueOf(String.valueOf(value));
    }

    private static Long lng(Object value) {
        if (value instanceof Number n) {
            return n.longValue();
        }
        try {
            return value == null ? null : Long.valueOf(String.valueOf(value));
        } catch (NumberFormatException ex) {
            return null;
        }
    }

    /**
     * Rundeck wraps some timestamps as {@code {"date":"..."} } and sends others
     * as a bare string, in the same response object.
     */
    private static Object nested(Object value) {
        if (value instanceof Map<?, ?> m) {
            return m.get("date");
        }
        return value;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> map(Object value) {
        return value instanceof Map ? (Map<String, Object>) value : Map.of();
    }

    private static List<String> strings(Object value) {
        if (value instanceof List<?> list) {
            return list.stream().map(String::valueOf).toList();
        }
        return List.of();
    }

    private static <T> List<T> safe(List<T> list) {
        return list == null ? List.of() : list;
    }

    private static Map<String, Object> safe(Map<String, Object> map) {
        return map == null ? Map.of() : map;
    }
}
