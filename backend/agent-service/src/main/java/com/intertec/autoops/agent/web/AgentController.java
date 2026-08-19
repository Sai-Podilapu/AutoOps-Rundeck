package com.intertec.autoops.agent.web;

import com.intertec.autoops.agent.client.AuditClient;
import com.intertec.autoops.agent.domain.Agent;
import com.intertec.autoops.agent.exception.AgentException;
import com.intertec.autoops.agent.service.AgentService;
import com.intertec.autoops.agent.web.dto.AgentRequest;
import com.intertec.autoops.agent.web.dto.AgentResponse;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * AI agents. Same paths, payloads and error codes the console already used
 * when this lived in core-service — the gateway simply points them here.
 * Tenant always from the token claim, never from the request.
 */
@RestController
public class AgentController {

    private final AgentService agentService;
    private final AuditClient auditClient;

    public AgentController(AgentService agentService, AuditClient auditClient) {
        this.agentService = agentService;
        this.auditClient = auditClient;
    }

    @GetMapping("/api/projects/{projectId}/agents")
    public List<AgentResponse> list(@PathVariable Long projectId,
                                    @AuthenticationPrincipal Jwt jwt) {
        String tenantId = tenant(jwt);
        boolean asProvider = isProvider(jwt);
        List<Agent> agents = agentService.list(tenantId, projectId);
        // Two batch resolves for the whole list — no per-tool round trips.
        var tools = agentService.describeTools(tenantId, projectId, agents);
        return agents.stream()
                .map(a -> AgentResponse.from(a, tools.get(a.getId()), asProvider))
                .toList();
    }

    /**
     * Building an agent is a PROVIDER capability. A tenant runs the agents
     * rolled out to it; it does not author personas. Rollout arrives over
     * /internal from core-service's provider surface.
     */
    @PostMapping("/api/projects/{projectId}/agents")
    @ResponseStatus(HttpStatus.CREATED)
    public AgentResponse create(@PathVariable Long projectId,
                                @Valid @RequestBody AgentRequest request,
                                @AuthenticationPrincipal Jwt jwt) {
        throw AgentException.forbidden("provider_authored_only",
                "Agents are built by your provider and rolled out to your workspace.");
    }

    @GetMapping("/api/agents/{id}")
    public AgentResponse get(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        return response(jwt, agentService.get(tenant(jwt), id));
    }

    @PutMapping("/api/agents/{id}")
    public AgentResponse update(@PathVariable Long id,
                                @Valid @RequestBody AgentRequest request,
                                @AuthenticationPrincipal Jwt jwt) {
        Agent agent = agentService.update(tenant(jwt), jwt.getTokenValue(), id, request.name(),
                request.description(), request.model(), request.instructions(), request.tools(),
                isProvider(jwt));
        audit("AGENT_UPDATED", jwt, agent);
        return response(jwt, agent);
    }

    public record ModelRequest(String model) {
    }

    /**
     * Point an agent at a different model. Separate from the general update
     * because it is the one change a tenant may make to a provider-managed
     * agent: the persona and the tool allow-list stay sealed, but the vendor
     * processing their data is theirs to choose.
     */
    @PostMapping("/api/agents/{id}/model")
    public AgentResponse setModel(@PathVariable Long id,
                                  @RequestBody ModelRequest request,
                                  @AuthenticationPrincipal Jwt jwt) {
        Agent agent = agentService.setModel(tenant(jwt), jwt.getTokenValue(), id,
                request.model());
        audit("AGENT_UPDATED", jwt, agent);
        return response(jwt, agent);
    }

    @PostMapping("/api/agents/{id}/enable")
    public AgentResponse enable(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        Agent agent = agentService.setEnabled(tenant(jwt), jwt.getTokenValue(), id, true);
        audit("AGENT_ENABLED", jwt, agent);
        return response(jwt, agent);
    }

    @PostMapping("/api/agents/{id}/disable")
    public AgentResponse disable(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        Agent agent = agentService.setEnabled(tenant(jwt), jwt.getTokenValue(), id, false);
        audit("AGENT_DISABLED", jwt, agent);
        return response(jwt, agent);
    }

    @DeleteMapping("/api/agents/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        Agent agent = agentService.get(tenant(jwt), id); // snapshot before it's gone
        agentService.delete(tenant(jwt), jwt.getTokenValue(), id, isProvider(jwt));
        audit("AGENT_DELETED", jwt, agent);
    }

    private AgentResponse response(Jwt jwt, Agent agent) {
        return AgentResponse.from(agent, agentService.describeTools(tenant(jwt), agent),
                isProvider(jwt));
    }

    private static boolean isProvider(Jwt jwt) {
        return "PROVIDER".equals(jwt.getClaimAsString("role"));
    }

    private void audit(String eventType, Jwt jwt, Agent agent) {
        auditClient.record(eventType, tenant(jwt), jwt.getSubject(), agent.getProjectId(),
                agent.getId(), agent.getName());
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw AgentException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
