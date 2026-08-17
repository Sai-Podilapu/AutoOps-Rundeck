package com.intertec.autoops.core.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * How Dify reports the outcome of a run.
 *
 * <p>In this package on purpose: {@code outcomeOf} is package-private because
 * nothing outside the client should be reading Dify's envelope, and testing it
 * from here keeps that true rather than widening the API for a test's benefit.
 */
class DifyAppClientTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private JsonNode json(String raw) throws Exception {
        return MAPPER.readTree(raw);
    }

    @Test
    void aFailedWorkflowInsideAnHttpTwoHundredIsAFailure() throws Exception {
        // The trap this pins down: Dify answers 200 for a workflow that failed,
        // and puts the truth in data.status. Trusting the HTTP status alone
        // would record every failed run as a success.
        DifyAppClient.RunOutcome outcome = DifyAppClient.outcomeOf(json("""
                {"data":{"id":"run-1","status":"failed","error":"Node 3 timed out",
                         "elapsed_time":2.5,"total_steps":3}}
                """));

        assertThat(outcome.success()).isFalse();
        assertThat(outcome.error()).isEqualTo("Node 3 timed out");
        assertThat(outcome.elapsedMs()).isEqualTo(2500L);
        assertThat(outcome.totalSteps()).isEqualTo(3);
        assertThat(outcome.workflowRunId()).isEqualTo("run-1");
    }

    @Test
    void aSucceededWorkflowCarriesItsOutputsAndNoError() throws Exception {
        DifyAppClient.RunOutcome outcome = DifyAppClient.outcomeOf(json(
                "{\"data\":{\"id\":\"run-2\",\"status\":\"succeeded\",\"outputs\":{\"text\":\"ok\"}}}"));

        assertThat(outcome.success()).isTrue();
        assertThat(outcome.error()).isNull();
        assertThat(outcome.outputs()).contains("ok");
    }

    @Test
    void aNonSuccessStatusWithNoErrorTextStillExplainsItself() throws Exception {
        // "stopped" carries no error string, and a blank failure reason in the
        // run log is indistinguishable from a bug in this translation.
        assertThat(DifyAppClient.outcomeOf(json("{\"data\":{\"status\":\"stopped\"}}")).error())
                .contains("stopped");
    }

    @Test
    void anEmptyResponseIsAFailureNotASilentSuccess() {
        DifyAppClient.RunOutcome outcome = DifyAppClient.outcomeOf(null);

        assertThat(outcome.success()).isFalse();
        assertThat(outcome.error()).isNotBlank();
    }

    @Test
    void absentOptionalNumbersStayNullRatherThanBecomingZero() throws Exception {
        // 0ms and "0 nodes ran" are claims; absent is the honest answer.
        DifyAppClient.RunOutcome outcome = DifyAppClient.outcomeOf(json(
                "{\"data\":{\"status\":\"succeeded\"}}"));

        assertThat(outcome.elapsedMs()).isNull();
        assertThat(outcome.totalSteps()).isNull();
        assertThat(outcome.outputs()).isNull();
    }
}
