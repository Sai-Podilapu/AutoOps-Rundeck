package com.intertec.autoops.workflow.client;

import com.intertec.autoops.workflow.config.WorkflowProperties;
import com.intertec.autoops.workflow.exception.WorkflowException;
import com.intertec.autoops.workflow.service.WorkflowComplexity.ComplexityRules;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpStatusCode;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Everything a workflow needs that core-service still owns: the project it
 * belongs to, the run history behind its stats, the tenant's approval rules,
 * and the audit trail.
 *
 * <p>Failure policy differs per call, on purpose:
 * <ul>
 *   <li>the PROJECT check is a gate — an unreachable core-service must not let
 *       a workflow be created against an unverified project, so it throws 503;
 *   <li>stats and rules are DECORATION — a workflow list must still render
 *       when core-service is down, so they degrade to empty/defaults;
 *   <li>audit is best-effort, exactly as it is inside core-service: it never
 *       breaks the mutation it documents.
 * </ul>
 */
@Component
public class CoreClient {

    private static final Logger log = LoggerFactory.getLogger(CoreClient.class);

    private final RestClient coreRestClient;
    private final String internalToken;

    public CoreClient(@Qualifier("coreRestClient") RestClient coreRestClient,
                      WorkflowProperties properties) {
        this.coreRestClient = coreRestClient;
        this.internalToken = properties.getCore().getInternalToken();
    }

    /** Run aggregates for one workflow, mirroring core's RunService.RunStats. */
    /** `running` is a live fact, not an aggregate: true while a run is
     * QUEUED or RUNNING, whatever started it. */
    public record RunStats(Long total, Integer successRate, Instant lastRunAt,
                           Long avgDurationMs, boolean running) {
    }

    /**
     * Asserts the project exists, is the tenant's, and is not archived.
     * Throws {@code project_not_found} (404) exactly as the monolith did.
     */
    public void requireProject(String tenantId, Long projectId) {
        try {
            coreRestClient.get()
                    .uri("/internal/projects/{id}?tenantId={tenantId}", projectId, tenantId)
                    .header("X-Internal-Token", internalToken)
                    .retrieve()
                    .onStatus(HttpStatusCode::is4xxClientError, (req, res) -> {
                        throw WorkflowException.notFound("project_not_found", "No such project");
                    })
                    .toBodilessEntity();
        } catch (WorkflowException ex) {
            throw ex;
        } catch (Exception ex) {
            // Fail CLOSED: without the check we cannot prove the project is the
            // caller's, and a workflow attached to someone else's project is
            // exactly the cross-tenant leak the FK used to make impossible.
            log.warn("Project check unavailable for {}/{}: {}", tenantId, projectId,
                    ex.getMessage());
            throw WorkflowException.serviceUnavailable("core_unavailable",
                    "Project validation is temporarily unavailable — please retry");
        }
    }

    /** Batch run stats for a project's workflows, keyed by workflow id. */
    public Map<Long, RunStats> statsForProject(String tenantId, Long projectId) {
        try {
            List<Map<String, Object>> rows = coreRestClient.get()
                    .uri("/internal/runs/stats?tenantId={tenantId}&targetType=WORKFLOW"
                            + "&projectId={projectId}", tenantId, projectId)
                    .header("X-Internal-Token", internalToken)
                    .retrieve()
                    .body(new ParameterizedTypeReference<List<Map<String, Object>>>() {
                    });
            Map<Long, RunStats> out = new HashMap<>();
            for (Map<String, Object> row : rows == null ? List.<Map<String, Object>>of() : rows) {
                Long targetId = asLong(row.get("targetId"));
                if (targetId != null) {
                    out.put(targetId, new RunStats(asLong(row.get("total")),
                            asInt(row.get("successRate")), asInstant(row.get("lastRunAt")),
                            asLong(row.get("avgDurationMs")),
                            Boolean.TRUE.equals(row.get("running"))));
                }
            }
            return out;
        } catch (Exception ex) {
            // Stats are decoration: a workflow list must still render.
            log.warn("Run stats unavailable for tenant {} project {}: {}", tenantId, projectId,
                    ex.getMessage());
            return Map.of();
        }
    }

    /** Stats for a single workflow; null when unknown or never run. */
    public RunStats statsForWorkflow(String tenantId, Long projectId, Long workflowId) {
        return statsForProject(tenantId, projectId).get(workflowId);
    }

    /**
     * The tenant's complexity rules (approval_settings). Falls back to the
     * PLATFORM DEFAULTS rather than to "nothing needs approval" — degrading
     * into a state where complex workflows stop being gated would be a
     * security regression, not a graceful one.
     */
    public ComplexityRules complexityRules(String tenantId) {
        try {
            Map<String, Object> body = coreRestClient.get()
                    .uri("/internal/approval-settings?tenantId={tenantId}", tenantId)
                    .header("X-Internal-Token", internalToken)
                    .retrieve()
                    .body(new ParameterizedTypeReference<Map<String, Object>>() {
                    });
            if (body == null) {
                return ComplexityRules.PLATFORM_DEFAULTS;
            }
            Integer threshold = asInt(body.get("complexNodeThreshold"));
            @SuppressWarnings("unchecked")
            List<String> risky = body.get("riskyTypes") instanceof List<?> list
                    ? (List<String>) list : null;
            return new ComplexityRules(
                    threshold != null ? threshold : ComplexityRules.PLATFORM_DEFAULTS.nodeThreshold(),
                    risky != null ? Set.copyOf(risky)
                            : ComplexityRules.PLATFORM_DEFAULTS.riskyTypes());
        } catch (Exception ex) {
            log.warn("Approval rules unavailable for tenant {} — using platform defaults: {}",
                    tenantId, ex.getMessage());
            return ComplexityRules.PLATFORM_DEFAULTS;
        }
    }

    /** Best-effort audit write into core-service's single trail. */
    public void audit(String eventType, String tenantId, String actor, Long projectId,
                      Long workflowId, String name) {
        try {
            Map<String, Object> body = new HashMap<>();
            body.put("eventType", eventType);
            body.put("tenantId", tenantId);
            body.put("actor", actor);
            body.put("projectId", projectId);
            body.put("targetType", "WORKFLOW");
            body.put("targetId", workflowId);
            body.put("targetName", name);
            coreRestClient.post()
                    .uri("/internal/audit")
                    .header("X-Internal-Token", internalToken)
                    .body(body)
                    .retrieve()
                    .toBodilessEntity();
        } catch (Exception ex) {
            // Recording must never break the mutation it documents.
            log.error("Failed to write audit event {}: {}", eventType, ex.getMessage());
        }
    }

    private static Long asLong(Object value) {
        return value instanceof Number n ? n.longValue() : null;
    }

    private static Integer asInt(Object value) {
        return value instanceof Number n ? n.intValue() : null;
    }

    private static Instant asInstant(Object value) {
        try {
            return value != null ? Instant.parse(value.toString()) : null;
        } catch (Exception ex) {
            return null;
        }
    }
}
