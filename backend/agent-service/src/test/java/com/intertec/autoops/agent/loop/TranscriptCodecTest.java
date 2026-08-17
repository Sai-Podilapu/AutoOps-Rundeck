package com.intertec.autoops.agent.loop;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.agent.exception.AgentException;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The transcript is the ONLY thing standing between an approval that comes
 * back two days later and a run that has to start over. Everything here is
 * about that: what goes in comes out, and what cannot come out says so loudly
 * rather than resuming with the middle of the conversation missing.
 */
class TranscriptCodecTest {

    private final TranscriptCodec codec = new TranscriptCodec(new ObjectMapper());

    @Test
    void roundTripsEveryMessageKind() {
        Map<String, Object> arguments = new LinkedHashMap<>();
        arguments.put("hostname", "app-01");
        arguments.put("threshold", 85);

        List<ChatMessage> original = List.of(
                new ChatMessage.User("Check disk on app-01"),
                new ChatMessage.Assistant("Let me look.",
                        List.of(new ToolCall("call_1", "job_14", arguments))),
                new ChatMessage.ToolResults(List.of(
                        ToolResult.ok("call_1", "Run #90 finished SUCCEEDED"))));

        List<ChatMessage> back = codec.read(codec.write(original));

        assertEquals(3, back.size());
        assertEquals("Check disk on app-01", ((ChatMessage.User) back.get(0)).text());

        ChatMessage.Assistant assistant = assertInstanceOf(ChatMessage.Assistant.class, back.get(1));
        assertEquals("Let me look.", assistant.text());
        assertEquals(1, assistant.toolCalls().size());
        assertEquals("call_1", assistant.toolCalls().getFirst().id());
        assertEquals("job_14", assistant.toolCalls().getFirst().name());
        assertEquals("app-01", assistant.toolCalls().getFirst().arguments().get("hostname"));

        ChatMessage.ToolResults results =
                assertInstanceOf(ChatMessage.ToolResults.class, back.get(2));
        assertEquals("call_1", results.results().getFirst().toolCallId());
        assertEquals("Run #90 finished SUCCEEDED", results.results().getFirst().content());
    }

    /**
     * The error flag is what tells a model a tool FAILED rather than returned
     * text about a failure. Losing it across a park/resume would have the
     * model treat a failed reboot as a successful one.
     */
    @Test
    void keepsTheErrorFlagOnAToolResult() {
        List<ChatMessage> back = codec.read(codec.write(List.of(
                new ChatMessage.Assistant("", List.of(new ToolCall("c1", "job_2", Map.of()))),
                new ChatMessage.ToolResults(List.of(
                        ToolResult.error("c1", "Run #91 finished FAILED"))))));

        ChatMessage.ToolResults results =
                assertInstanceOf(ChatMessage.ToolResults.class, back.get(1));
        assertTrue(results.results().getFirst().isError());
    }

    /**
     * A partially answered turn is the whole point of the resume path: two
     * calls asked for, one answered. The shape has to survive so the loop can
     * work out what is still outstanding.
     */
    @Test
    void roundTripsAPartiallyAnsweredTurn() {
        List<ChatMessage> back = codec.read(codec.write(List.of(
                new ChatMessage.User("Patch both servers"),
                new ChatMessage.Assistant("", List.of(
                        new ToolCall("c1", "job_1", Map.of()),
                        new ToolCall("c2", "job_2", Map.of()))),
                new ChatMessage.ToolResults(List.of(ToolResult.ok("c1", "done"))))));

        ChatMessage.Assistant assistant = assertInstanceOf(ChatMessage.Assistant.class, back.get(1));
        ChatMessage.ToolResults results =
                assertInstanceOf(ChatMessage.ToolResults.class, back.get(2));

        assertEquals(2, assistant.toolCalls().size());
        assertEquals(1, results.results().size());
        assertEquals("c1", results.results().getFirst().toolCallId());
    }

    @Test
    void emptyTranscriptReadsAsAnEmptyConversation() {
        assertTrue(codec.read(null).isEmpty());
        assertTrue(codec.read("  ").isEmpty());
    }

    /**
     * Deliberately NOT a silent empty list. Resuming a conversation whose
     * middle could not be read would have the model re-run tools it has
     * already run — against live infrastructure.
     */
    @Test
    void refusesToReadACorruptTranscript() {
        AgentException ex = assertThrows(AgentException.class, () -> codec.read("{not json"));
        assertEquals("transcript_unreadable", ex.getError());
    }

    @Test
    void refusesATranscriptWithAnUnknownRole() {
        AgentException ex = assertThrows(AgentException.class,
                () -> codec.read("[{\"role\":\"system\",\"text\":\"hi\"}]"));
        assertEquals("transcript_unreadable", ex.getError());
    }
}
