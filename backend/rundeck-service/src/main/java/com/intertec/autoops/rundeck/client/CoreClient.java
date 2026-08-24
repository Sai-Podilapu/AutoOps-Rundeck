package com.intertec.autoops.rundeck.client;

import com.intertec.autoops.rundeck.config.RundeckProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.util.HashMap;
import java.util.Map;

/**
 * This service's one dependency on core-service: the audit trail.
 *
 * <p>AutoOps keeps ONE trail. A Rundeck job dispatched from here has to land in
 * the same table as the jobs, workflows and approvals it sits beside, or the
 * Audit page stops being an answer to "what happened in this workspace".
 *
 * <p><strong>Event types are reused, not invented.</strong> core-service's
 * {@code CoreAuditEventType} is a database ENUM, so a new value means a
 * migration in another service's schema. The existing connection and dispatch
 * verbs already describe exactly what happens here, and {@code targetType} is a
 * free string — so a Rundeck event is recorded as, for example,
 * {@code CONNECTION_VERIFIED} with {@code targetType=RUNDECK}. The trail stays
 * readable and no other service's schema has to move for this one.
 *
 * <p>Writes are best-effort, exactly as they are inside core-service: recording
 * an action must never break the action.
 */
@Component
public class CoreClient {

    private static final Logger log = LoggerFactory.getLogger(CoreClient.class);

    /** Marks every row this service writes, so the Audit page can group them. */
    public static final String TARGET_TYPE = "RUNDECK";

    private final RestClient coreRestClient;
    private final String internalToken;

    public CoreClient(@Qualifier("coreRestClient") RestClient coreRestClient,
                      RundeckProperties properties) {
        this.coreRestClient = coreRestClient;
        this.internalToken = properties.getCore().getInternalToken();
    }

    public void audit(String eventType, String tenantId, String actor, Long targetId,
                      String targetName, String detail) {
        try {
            Map<String, Object> body = new HashMap<>();
            body.put("eventType", eventType);
            body.put("tenantId", tenantId);
            body.put("actor", actor);
            body.put("targetType", TARGET_TYPE);
            body.put("targetId", targetId);
            body.put("targetName", targetName);
            body.put("detail", detail);
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
