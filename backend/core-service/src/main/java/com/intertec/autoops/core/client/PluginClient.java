package com.intertec.autoops.core.client;

import com.intertec.autoops.core.config.CoreProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Reports job and workflow lifecycle events to plugin-service, which decides
 * whose Slack, Teams, Outlook, Gmail or GitHub they reach.
 *
 * <p><b>This class never throws.</b> That is the entire failure policy, and it
 * is the opposite of {@link WorkflowClient}'s: a workflow that cannot be
 * fetched must stop a run, because running the wrong definition is worse than
 * not running. A notification that cannot be delivered must stop nothing. If
 * plugin-service is down, the run still succeeds or fails on its own terms and
 * the platform simply says so in the log.
 *
 * <p>Nor does it retry. This sits on the run engine's thread between steps, so
 * a retry loop here would hold a run open waiting on a service that is already
 * unhealthy. plugin-service owns delivery retries; core-service owns getting
 * the event handed over once.
 */
@Component
public class PluginClient {

    private static final Logger log = LoggerFactory.getLogger(PluginClient.class);

    private final RestClient pluginRestClient;
    private final String internalToken;
    private final boolean enabled;

    public PluginClient(@Qualifier("pluginRestClient") RestClient pluginRestClient,
                        CoreProperties properties) {
        this.pluginRestClient = pluginRestClient;
        this.internalToken = properties.getPlugin().getInternalToken();
        this.enabled = properties.getPlugin().isEnabled();
    }

    /** One lifecycle event, ready to post. Mirrors plugin-service's request DTO. */
    public record LifecycleEvent(
            String tenantId,
            String targetType,
            Long targetId,
            String targetName,
            String event,
            Long runId,
            Long projectId,
            String projectName,
            String triggeredBy,
            String detail,
            Instant occurredAt,
            Long durationSeconds) {
    }

    public void publish(LifecycleEvent event) {
        if (!enabled) {
            return;
        }
        try {
            pluginRestClient.post()
                    .uri("/internal/events")
                    .header("X-Internal-Token", internalToken)
                    .body(toBody(event))
                    .retrieve()
                    .toBodilessEntity();
        } catch (Exception ex) {
            // Debug, not warn: with plugin-service intentionally not started,
            // this would otherwise log on every status change of every run.
            log.debug("Could not report {} for {} {} (tenant {}): {}",
                    event.event(), event.targetType(), event.targetId(),
                    event.tenantId(), ex.getMessage());
        }
    }

    /** Batch form for the watchdog, which finds several missed jobs at once. */
    public void publishAll(List<LifecycleEvent> events) {
        if (!enabled || events.isEmpty()) {
            return;
        }
        try {
            pluginRestClient.post()
                    .uri("/internal/events/batch")
                    .header("X-Internal-Token", internalToken)
                    .body(events.stream().map(PluginClient::toBody).toList())
                    .retrieve()
                    .toBodilessEntity();
        } catch (Exception ex) {
            log.debug("Could not report {} lifecycle event(s): {}",
                    events.size(), ex.getMessage());
        }
    }

    /**
     * Built by hand rather than serialising the record directly: nulls have to
     * survive to the wire (a MISSED event legitimately has no runId), and
     * HashMap allows them where {@code Map.of} does not.
     */
    private static Map<String, Object> toBody(LifecycleEvent event) {
        Map<String, Object> body = new HashMap<>();
        body.put("tenantId", event.tenantId());
        body.put("targetType", event.targetType());
        body.put("targetId", event.targetId());
        body.put("targetName", event.targetName());
        body.put("event", event.event());
        body.put("runId", event.runId());
        body.put("projectId", event.projectId());
        body.put("projectName", event.projectName());
        body.put("triggeredBy", event.triggeredBy());
        body.put("detail", event.detail());
        body.put("occurredAt", event.occurredAt() == null
                ? Instant.now().toString() : event.occurredAt().toString());
        body.put("durationSeconds", event.durationSeconds());
        return body;
    }
}
