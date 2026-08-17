package com.intertec.autoops.workflow.client;

import com.intertec.autoops.workflow.config.WorkflowProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.util.Map;

/**
 * The other half of the shared MAX_AUTOMATIONS budget. Workflows and agents
 * are both automations and draw on ONE plan allowance, so creating a workflow
 * has to know how many agents the tenant holds — which now lives in another
 * service.
 *
 * <p>Unreachable agent-service counts as ZERO agents rather than failing the
 * create. The alternative is refusing to create workflows whenever
 * agent-service is down, which trades a rare over-count (a tenant briefly
 * squeezing past its automation limit) for an outage in the primary feature.
 * The over-count self-corrects on the next successful call.
 */
@Component
public class AgentClient {

    private static final Logger log = LoggerFactory.getLogger(AgentClient.class);

    private final RestClient agentRestClient;
    private final String internalToken;

    public AgentClient(@Qualifier("agentRestClient") RestClient agentRestClient,
                       WorkflowProperties properties) {
        this.agentRestClient = agentRestClient;
        this.internalToken = properties.getAgent().getInternalToken();
    }

    public long countForTenant(String tenantId) {
        try {
            Map<String, Object> body = agentRestClient.get()
                    .uri("/internal/agents/count?tenantId={tenantId}", tenantId)
                    .header("X-Internal-Token", internalToken)
                    .retrieve()
                    .body(new ParameterizedTypeReference<Map<String, Object>>() {
                    });
            return body != null && body.get("count") instanceof Number n ? n.longValue() : 0L;
        } catch (Exception ex) {
            log.warn("Agent count unavailable for tenant {} — counting 0 toward the automation "
                    + "budget: {}", tenantId, ex.getMessage());
            return 0L;
        }
    }
}
