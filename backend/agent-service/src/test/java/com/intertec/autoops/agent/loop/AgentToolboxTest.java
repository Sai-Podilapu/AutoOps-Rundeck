package com.intertec.autoops.agent.loop;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.agent.client.AutomationClient;
import com.intertec.autoops.agent.client.ToolTargetClient;
import com.intertec.autoops.agent.domain.Agent;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;

/**
 * The allow-list is an agent's entire authority, and this class is where a
 * name the model returned becomes a thing that gets executed. So the cases
 * that matter are the ones where the answer must be "no": a name that was
 * never granted, a target that has since moved out of the project, a workflow
 * that cannot actually be run.
 */
class AgentToolboxTest {

    private static final String TENANT = "acme-corp-cafe0123";
    private static final long PROJECT = 7L;

    private ToolTargetClient toolTargets;
    private AutomationClient automations;
    private AgentToolbox toolbox;

    @BeforeEach
    void setUp() {
        toolTargets = Mockito.mock(ToolTargetClient.class);
        automations = Mockito.mock(AutomationClient.class);
        toolbox = new AgentToolbox(new ObjectMapper(), toolTargets, automations);

        // Default: nothing exists. Each test grants exactly what it needs, so
        // an accidental extra tool cannot slip in unnoticed.
        when(toolTargets.findJob(anyString(), anyLong())).thenReturn(Optional.empty());
        when(toolTargets.findWorkflow(anyString(), anyLong())).thenReturn(Optional.empty());
        when(automations.workflowInputs(anyString(), anyLong()))
                .thenReturn(new AutomationClient.WorkflowInputs(List.of(), null));
    }

    private Agent agent(String tools) {
        Agent agent = new Agent();
        agent.setTenantId(TENANT);
        agent.setProjectId(PROJECT);
        agent.setName("Patch Operator");
        agent.setTools(tools);
        return agent;
    }

    @Test
    void offersAGrantedJobUnderADerivedName() {
        when(toolTargets.findJob(TENANT, 14L))
                .thenReturn(Optional.of(new ToolTargetClient.Target(14L, PROJECT, "Nightly patch")));

        AgentToolbox.Toolbox built = toolbox.build(agent("[{\"type\":\"JOB\",\"id\":14}]"));

        assertEquals(1, built.specs().size());
        assertEquals("job_14", built.specs().getFirst().name());
        // The human name is what the model actually reads.
        assertTrue(built.specs().getFirst().description().contains("Nightly patch"));

        AgentToolbox.Tool tool = built.resolve("job_14");
        assertEquals("JOB", tool.type());
        assertEquals(14L, tool.targetId());
    }

    /** The hallucination case. Nothing outside the list may resolve, ever. */
    @Test
    void refusesANameThatWasNeverGranted() {
        when(toolTargets.findJob(TENANT, 14L))
                .thenReturn(Optional.of(new ToolTargetClient.Target(14L, PROJECT, "Nightly patch")));

        AgentToolbox.Toolbox built = toolbox.build(agent("[{\"type\":\"JOB\",\"id\":14}]"));

        assertNull(built.resolve("job_99"));
        assertNull(built.resolve("delete_everything"));
        assertNull(built.resolve("workflow_14"));
    }

    /**
     * The allow-list holds IDs, and a job can be moved to another project
     * after the agent was saved. Re-checking at run time is the difference
     * between a stale id and an agent operating something it was never granted.
     */
    @Test
    void dropsAJobThatHasMovedOutOfTheProject() {
        when(toolTargets.findJob(TENANT, 14L))
                .thenReturn(Optional.of(new ToolTargetClient.Target(14L, 999L, "Someone else's job")));

        AgentToolbox.Toolbox built = toolbox.build(agent("[{\"type\":\"JOB\",\"id\":14}]"));

        assertTrue(built.isEmpty());
        assertNull(built.resolve("job_14"));
        assertEquals(1, built.skipped().size());
    }

    @Test
    void dropsAJobThatNoLongerExists() {
        AgentToolbox.Toolbox built = toolbox.build(agent("[{\"type\":\"JOB\",\"id\":14}]"));

        assertTrue(built.isEmpty());
        assertFalse(built.skipped().isEmpty());
    }

    /** A Dify workflow's published form becomes the tool's arguments. */
    @Test
    void exposesAWorkflowsInputFormAsTheToolSchema() {
        when(toolTargets.findWorkflow(TENANT, 3L))
                .thenReturn(Optional.of(new ToolTargetClient.Target(3L, PROJECT, "Reset password")));
        when(automations.workflowInputs(TENANT, 3L)).thenReturn(
                new AutomationClient.WorkflowInputs(List.of(
                        new AutomationClient.InputField("samAccountName", "User", "text-input",
                                true, List.of()),
                        new AutomationClient.InputField("region", "Region", "select", false,
                                List.of("emea", "apac"))),
                        null));

        AgentToolbox.Toolbox built = toolbox.build(agent("[{\"type\":\"WORKFLOW\",\"id\":3}]"));

        Map<String, Object> schema = built.specs().getFirst().inputSchema();
        @SuppressWarnings("unchecked")
        Map<String, Object> properties = (Map<String, Object>) schema.get("properties");

        assertTrue(properties.containsKey("samAccountName"));
        assertEquals(List.of("samAccountName"), schema.get("required"));

        @SuppressWarnings("unchecked")
        Map<String, Object> region = (Map<String, Object>) properties.get("region");
        // A select's options ARE the contract; stating them beats a failure
        // inside Dify that the model cannot act on.
        assertEquals(List.of("emea", "apac"), region.get("enum"));
    }

    /**
     * A workflow whose Dify key is missing or revoked is left OUT rather than
     * offered. A tool the model can see is one it will eventually call, and
     * one that fails on every call burns steps and teaches it nothing.
     */
    @Test
    void dropsAWorkflowWhoseInputFormCannotBeRead() {
        when(toolTargets.findWorkflow(TENANT, 3L))
                .thenReturn(Optional.of(new ToolTargetClient.Target(3L, PROJECT, "Reset password")));
        when(automations.workflowInputs(TENANT, 3L)).thenReturn(
                new AutomationClient.WorkflowInputs(List.of(), "No Dify key configured"));

        AgentToolbox.Toolbox built = toolbox.build(agent("[{\"type\":\"WORKFLOW\",\"id\":3}]"));

        assertTrue(built.isEmpty());
        assertTrue(built.skipped().getFirst().contains("No Dify key configured"));
    }

    /** Corrupt JSON must leave the agent powerless, not unbounded. */
    @Test
    void aCorruptAllowListGrantsNothing() {
        assertTrue(toolbox.build(agent("{not json")).isEmpty());
        assertTrue(toolbox.build(agent(null)).isEmpty());
        assertTrue(toolbox.build(agent("\"JOB\"")).isEmpty());
    }
}
