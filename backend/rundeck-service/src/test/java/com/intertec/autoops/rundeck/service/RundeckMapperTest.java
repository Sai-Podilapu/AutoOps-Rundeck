package com.intertec.autoops.rundeck.service;

import com.intertec.autoops.rundeck.web.dto.RundeckViews.JobDetailView;
import com.intertec.autoops.rundeck.web.dto.RundeckViews.NodeView;
import com.intertec.autoops.rundeck.web.dto.RundeckViews.OptionView;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The mapper's whole job is tolerating a payload we did not author. These cases
 * are the shapes Rundeck actually varies between versions and plugin sources —
 * each one shipped as a bug in some integration somewhere.
 */
class RundeckMapperTest {

    private final RundeckMapper mapper = new RundeckMapper();

    @Test
    @DisplayName("options as a LIST of objects")
    void optionsAsList() {
        List<OptionView> options = mapper.options(List.of(
                Map.of("name", "env", "required", true, "value", "staging",
                        "values", List.of("staging", "prod"), "enforced", true),
                Map.of("name", "notes")));

        assertThat(options).hasSize(2);
        assertThat(options.get(0).name()).isEqualTo("env");
        assertThat(options.get(0).required()).isTrue();
        assertThat(options.get(0).defaultValue()).isEqualTo("staging");
        assertThat(options.get(0).values()).containsExactly("staging", "prod");
        assertThat(options.get(0).enforced()).isTrue();
        assertThat(options.get(1).required()).isFalse();
    }

    @Test
    @DisplayName("options as a MAP keyed by name — the other shape Rundeck emits")
    void optionsAsMap() {
        List<OptionView> options = mapper.options(Map.of(
                "env", Map.of("required", true, "value", "prod")));

        // A run form that rendered nothing here would submit the job with every
        // option at its default and never tell the operator.
        assertThat(options).hasSize(1);
        assertThat(options.get(0).name()).isEqualTo("env");
        assertThat(options.get(0).required()).isTrue();
    }

    @Test
    @DisplayName("a secure option defaults to NOT value-exposed")
    void secureOptionDefaults() {
        List<OptionView> options = mapper.options(List.of(
                Map.of("name", "password", "secure", true),
                Map.of("name", "apiKey", "secure", true, "valueExposed", true),
                Map.of("name", "plain")));

        // Secure + not exposed is Rundeck's "Secure Remote Authentication": the
        // value reaches node executors only. Defaulting exposed=true here would
        // let the console echo a credential it must never show.
        assertThat(options.get(0).secure()).isTrue();
        assertThat(options.get(0).valueExposed()).isFalse();
        assertThat(options.get(1).valueExposed()).isTrue();
        assertThat(options.get(2).secure()).isFalse();
        assertThat(options.get(2).valueExposed()).isTrue();
    }

    @Test
    @DisplayName("missing options is an empty list, not a null")
    void noOptions() {
        assertThat(mapper.options(null)).isEmpty();
        assertThat(mapper.options("not-a-collection")).isEmpty();
    }

    @Test
    @DisplayName("the node filter is read out of nodefilters.filter")
    void jobDetailReadsNodeFilter() {
        JobDetailView job = mapper.jobDetail(Map.of(
                "id", "abc", "name", "Restart", "project", "Ops",
                "nodefilters", Map.of("filter", "tags: web+prod"),
                "options", List.of(Map.of("name", "env"))));

        assertThat(job.nodeFilter()).isEqualTo("tags: web+prod");
        assertThat(job.options()).hasSize(1);
    }

    @Test
    @DisplayName("a job with no nodefilters block maps to a null filter, not a crash")
    void jobDetailWithoutNodeFilters() {
        JobDetailView job = mapper.jobDetail(Map.of("id", "abc", "name", "Notify"));

        assertThat(job.nodeFilter()).isNull();
        assertThat(job.options()).isEmpty();
    }

    @Test
    @DisplayName("tags arrive as a comma string OR a list — both become a list")
    void tagsBothShapes() {
        List<NodeView> fromString = mapper.nodes(Map.of(
                "web-01", Map.of("hostname", "10.0.0.1", "tags", "web, prod ,linux")));
        List<NodeView> fromList = mapper.nodes(Map.of(
                "web-02", Map.of("hostname", "10.0.0.2", "tags", List.of("web", "prod"))));

        assertThat(fromString.get(0).tags()).containsExactly("web", "prod", "linux");
        assertThat(fromList.get(0).tags()).containsExactly("web", "prod");
    }

    @Test
    @DisplayName("the node map key is the identity when nodename is absent")
    void nodeNameFallsBackToKey() {
        List<NodeView> nodes = mapper.nodes(Map.of(
                "db-01", Map.of("hostname", "10.0.0.9", "osFamily", "unix")));

        assertThat(nodes).hasSize(1);
        assertThat(nodes.get(0).name()).isEqualTo("db-01");
        assertThat(nodes.get(0).osFamily()).isEqualTo("unix");
    }

    @Test
    @DisplayName("unnamed node attributes survive into `attributes`")
    void unknownNodeAttributesArePreserved() {
        List<NodeView> nodes = mapper.nodes(Map.of(
                "web-01", Map.of("hostname", "h", "tags", "web",
                        "custom-cmdb-id", "CI-4417")));

        assertThat(nodes.get(0).attributes()).containsEntry("custom-cmdb-id", "CI-4417");
        // The fields we named are not duplicated into the bag.
        assertThat(nodes.get(0).attributes()).doesNotContainKey("hostname");
    }

    @Test
    @DisplayName("nodes are sorted so the list does not reshuffle between polls")
    void nodesAreSorted() {
        List<NodeView> nodes = mapper.nodes(Map.of(
                "web-02", Map.of("hostname", "b"),
                "app-01", Map.of("hostname", "a"),
                "db-03", Map.of("hostname", "c")));

        assertThat(nodes).extracting(NodeView::name)
                .containsExactly("app-01", "db-03", "web-02");
    }

    @Test
    @DisplayName("a date sent as {date: ...} and one sent bare both map")
    void executionDatesBothShapes() {
        var wrapped = mapper.execution(Map.of(
                "id", 1, "status", "succeeded",
                "date-started", Map.of("date", "2026-08-20T09:00:00Z")));
        var bare = mapper.execution(Map.of(
                "id", 2, "status", "running", "date-started", "2026-08-20T10:00:00Z"));

        assertThat(wrapped.dateStarted()).isEqualTo("2026-08-20T09:00:00Z");
        assertThat(bare.dateStarted()).isEqualTo("2026-08-20T10:00:00Z");
    }

    @Test
    @DisplayName("an ad-hoc dispatch nests the execution — both shapes must map")
    void adHocResponseIsUnwrapped() {
        // /run/script answers {"message": "...", "execution": {...}} while
        // /job/{id}/run answers with the execution flat. Reading only the flat
        // shape meant a step that ran but could be neither awaited nor aborted.
        var nested = mapper.execution(Map.of(
                "message", "Immediate execution scheduled (2)",
                "execution", Map.of("id", 2, "status", "running")));
        var flat = mapper.execution(Map.of("id", 7, "status", "succeeded"));

        assertThat(nested.id()).isEqualTo(2L);
        assertThat(nested.status()).isEqualTo("running");
        assertThat(flat.id()).isEqualTo(7L);
    }

    @Test
    @DisplayName("log entries prefer absolute_time and carry the step context")
    void logEntries() {
        var log = mapper.log(Map.of(
                "execCompleted", true, "offset", "4096",
                "entries", List.of(Map.of(
                        "absolute_time", "2026-08-20T09:00:01Z", "time", "09:00:01",
                        "level", "NORMAL", "node", "web-01", "stepctx", "1",
                        "log", "restarting"))));

        assertThat(log.execCompleted()).isTrue();
        assertThat(log.offset()).isEqualTo("4096");
        assertThat(log.entries()).hasSize(1);
        assertThat(log.entries().get(0).time()).isEqualTo("2026-08-20T09:00:01Z");
        assertThat(log.entries().get(0).node()).isEqualTo("web-01");
        assertThat(log.entries().get(0).step()).isEqualTo("1");
    }

    @Test
    @DisplayName("an empty output response is an empty window, not a null")
    void emptyLog() {
        var log = mapper.log(Map.of());

        assertThat(log.entries()).isEmpty();
        assertThat(log.execCompleted()).isFalse();
    }
}
