package com.intertec.autoops.agent.web.dto;

import com.intertec.autoops.agent.domain.Agent;
import com.intertec.autoops.agent.service.AgentService.ToolView;

import java.time.Instant;
import java.util.List;

/**
 * What the console sees. {@code tools} comes back RESOLVED (type, id, target
 * name, and whether the target still exists).
 *
 * <p><b>Sealing.</b> A PROVIDER-built agent is the provider's product, so
 * {@code instructions} — the operating brief that makes the agent worth
 * buying — is withheld from every caller that is not itself a PROVIDER.
 *
 * <p>What is NOT withheld, on purpose:
 * <ul>
 *   <li>{@code tools} — the allow-list is the security boundary. A customer
 *       who cannot see what an agent is permitted to touch cannot meaningfully
 *       consent to it running in their workspace, so it is disclosed even when
 *       the persona is sealed.</li>
 *   <li>{@code model} — customers are entitled to know what model runs over
 *       their data.</li>
 * </ul>
 * Hiding either would trade a real governance guarantee for no extra
 * protection: neither reveals how the agent reasons.
 */
public record AgentResponse(
        Long id,
        Long projectId,
        String name,
        String description,
        String model,
        String instructions,
        List<ToolView> tools,
        int toolCount,
        boolean enabled,
        String origin,
        boolean editable,
        String createdBy,
        Instant createdAt,
        Instant updatedAt) {

    public static AgentResponse from(Agent agent, List<ToolView> tools,
                                     boolean callerIsProvider) {
        boolean sealed = agent.isProviderAuthored() && !callerIsProvider;
        return new AgentResponse(agent.getId(), agent.getProjectId(), agent.getName(),
                agent.getDescription(), agent.getModel(),
                sealed ? null : agent.getInstructions(),
                tools != null ? tools : List.of(), agent.getToolCount(), agent.isEnabled(),
                agent.getOrigin().name(), !sealed,
                agent.getCreatedBy(), agent.getCreatedAt(), agent.getUpdatedAt());
    }
}
