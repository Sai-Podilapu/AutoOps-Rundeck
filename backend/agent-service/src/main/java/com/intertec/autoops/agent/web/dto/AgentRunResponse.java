package com.intertec.autoops.agent.web.dto;

import com.intertec.autoops.agent.domain.AgentRun;
import com.intertec.autoops.agent.domain.AgentRunStep;

import java.time.Instant;
import java.util.List;

/**
 * A run as the console shows it.
 *
 * <p>The {@code transcript} column is NOT here, on any path. It is the raw
 * provider-neutral message history, and it carries the agent's system prompt —
 * which for a PROVIDER-authored agent is exactly the persona the tenant is
 * never shown. The steps below say everything an operator needs about what
 * happened, without that leak.
 */
public record AgentRunResponse(Long id, Long agentId, Long projectId, String status,
                               String input, String output, String error,
                               String model, String vendor,
                               int stepCount, int maxSteps,
                               String approvalReference,
                               long promptTokens, long completionTokens,
                               String createdBy, Instant createdAt, Instant startedAt,
                               Instant finishedAt, List<Step> steps) {

    /**
     * @param isError a tool that FAILED, which is different from a step that
     *                is missing — the model was told and got to react
     */
    public record Step(Long id, int seq, String kind, String toolType, Long toolTargetId,
                       String toolName, String request, String response, boolean isError,
                       Long durationMs, Instant createdAt) {

        public static Step from(AgentRunStep step) {
            return new Step(step.getId(), step.getSeq(), step.getKind().name(),
                    step.getToolType(), step.getToolTargetId(), step.getToolName(),
                    step.getRequest(), step.getResponse(), step.isError(),
                    step.getDurationMs(), step.getCreatedAt());
        }
    }

    /** List rows: no steps, because a list of 100 runs does not need them. */
    public static AgentRunResponse summary(AgentRun run) {
        return from(run, null);
    }

    public static AgentRunResponse from(AgentRun run, List<AgentRunStep> steps) {
        return new AgentRunResponse(run.getId(), run.getAgentId(), run.getProjectId(),
                run.getStatus().name(), run.getInput(), run.getOutput(), run.getError(),
                run.getModel(), run.getVendor(), run.getStepCount(), run.getMaxSteps(),
                run.getApprovalReference(), run.getPromptTokens(), run.getCompletionTokens(),
                run.getCreatedBy(), run.getCreatedAt(), run.getStartedAt(), run.getFinishedAt(),
                steps == null ? null : steps.stream().map(Step::from).toList());
    }
}
