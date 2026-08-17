package com.intertec.autoops.agent.client;

import com.intertec.autoops.agent.config.AgentProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.util.HashMap;
import java.util.Map;

/**
 * Agent mutations land in core-service's audit trail, next to the project and
 * job events they relate to. The trail stays SINGLE across the split — the
 * console's Audit page reads one table, and an operator asking "who changed
 * what in this project" should not have to know which service owns each row.
 *
 * <p>Best-effort, exactly as audit is inside core-service: recording must
 * never break the mutation it documents.
 */
@Component
public class AuditClient {

    private static final Logger log = LoggerFactory.getLogger(AuditClient.class);

    private final RestClient coreRestClient;
    private final String internalToken;

    public AuditClient(@Qualifier("coreRestClient") RestClient coreRestClient,
                       AgentProperties properties) {
        this.coreRestClient = coreRestClient;
        this.internalToken = properties.getCore().getInternalToken();
    }

    public void record(String eventType, String tenantId, String actor, Long projectId,
                       Long agentId, String name) {
        try {
            Map<String, Object> body = new HashMap<>();
            body.put("eventType", eventType);
            body.put("tenantId", tenantId);
            body.put("actor", actor);
            body.put("projectId", projectId);
            body.put("targetType", "AGENT");
            body.put("targetId", agentId);
            body.put("targetName", name);
            coreRestClient.post()
                    .uri("/internal/audit")
                    .header("X-Internal-Token", internalToken)
                    .body(body)
                    .retrieve()
                    .toBodilessEntity();
        } catch (Exception ex) {
            log.error("Failed to write audit event {}: {}", eventType, ex.getMessage());
        }
    }
}
