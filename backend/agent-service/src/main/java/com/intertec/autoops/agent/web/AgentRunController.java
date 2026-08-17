package com.intertec.autoops.agent.web;

import com.intertec.autoops.agent.client.AuditClient;
import com.intertec.autoops.agent.domain.AgentRun;
import com.intertec.autoops.agent.exception.AgentException;
import com.intertec.autoops.agent.service.AgentRunService;
import com.intertec.autoops.agent.web.dto.AgentRunResponse;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Running an agent, and reading what happened.
 *
 * <p>Note what is NOT here: no "approve" endpoint. An agent's approval is an
 * ordinary approval in the ordinary inbox, decided on the ordinary approvals
 * screen by an ordinary admin. A second approval UI for agents would be a
 * second place to look on the day something ran that should not have.
 *
 * <p>Running is a TENANT capability, unlike building — a tenant runs the
 * agents rolled out to it. Tenant always comes from the token.
 */
@RestController
public class AgentRunController {

    private final AgentRunService runService;
    private final AuditClient auditClient;

    public AgentRunController(AgentRunService runService, AuditClient auditClient) {
        this.runService = runService;
        this.auditClient = auditClient;
    }

    /** @param input what the agent is being asked to do */
    public record StartRunRequest(
            @NotBlank(message = "Tell the agent what to do")
            @Size(max = 8000, message = "Keep the request under 8000 characters")
            String input) {
    }

    /**
     * Starts a run and returns it immediately in PENDING or RUNNING.
     *
     * <p>202, not 201: the run has been accepted, and the thing the caller
     * actually wants — the answer — does not exist yet. The console polls
     * {@code GET /api/agent-runs/{id}} for it.
     */
    @PostMapping("/api/agents/{id}/runs")
    @ResponseStatus(HttpStatus.ACCEPTED)
    public AgentRunResponse start(@PathVariable Long id,
                                  @RequestBody StartRunRequest request,
                                  @AuthenticationPrincipal Jwt jwt) {
        String tenantId = tenant(jwt);
        AgentRun run = runService.start(tenantId, jwt.getSubject(), jwt.getTokenValue(), id,
                request == null ? null : request.input());
        auditClient.record("AGENT_RUN_STARTED", tenantId, jwt.getSubject(), run.getProjectId(),
                run.getId(), "Agent #" + id);
        return AgentRunResponse.summary(run);
    }

    @GetMapping("/api/agents/{id}/runs")
    public List<AgentRunResponse> list(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        return runService.listForAgent(tenant(jwt), id).stream()
                .map(AgentRunResponse::summary)
                .toList();
    }

    /** The full record: the run plus every step, in order. */
    @GetMapping("/api/agent-runs/{runId}")
    public AgentRunResponse get(@PathVariable Long runId, @AuthenticationPrincipal Jwt jwt) {
        String tenantId = tenant(jwt);
        AgentRun run = runService.get(tenantId, runId);
        return AgentRunResponse.from(run, runService.steps(tenantId, runId));
    }

    /**
     * Stops the loop. Deliberately does NOT stop an automation the agent has
     * already started — that run belongs to core-service and is cancelled from
     * the Runs view. The response says so rather than implying otherwise.
     */
    @PostMapping("/api/agent-runs/{runId}/cancel")
    public AgentRunResponse cancel(@PathVariable Long runId, @AuthenticationPrincipal Jwt jwt) {
        String tenantId = tenant(jwt);
        AgentRun run = runService.cancel(tenantId, runId);
        auditClient.record("AGENT_RUN_CANCELLED", tenantId, jwt.getSubject(), run.getProjectId(),
                run.getId(), "Agent run #" + runId);
        return AgentRunResponse.summary(run);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw AgentException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
