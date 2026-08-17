package com.intertec.autoops.plugin.web;

import com.intertec.autoops.plugin.service.DispatchService;
import com.intertec.autoops.plugin.web.dto.RunEventRequest;
import jakarta.validation.Valid;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

/**
 * Where core-service reports job and workflow lifecycle events.
 *
 * <p>Guarded by {@code InternalTokenFilter}, never routed by the gateway. The
 * token authenticates the caller; the {@code tenantId} in each body is what
 * scopes the fan-out.
 *
 * <p>Returns as soon as the matching sends are queued. A run must never be
 * held up waiting for Slack, and a notification failing must never fail the
 * run that caused it — core-service treats this call as best-effort.
 */
@RestController
public class InternalEventController {

    private static final Logger log = LoggerFactory.getLogger(InternalEventController.class);

    /** Bounded so one malformed batch cannot queue unbounded work. */
    private static final int MAX_BATCH = 100;

    private final DispatchService dispatchService;

    public InternalEventController(DispatchService dispatchService) {
        this.dispatchService = dispatchService;
    }

    @PostMapping("/internal/events")
    public Map<String, Object> event(@Valid @RequestBody RunEventRequest request) {
        int queued = dispatchService.dispatch(request.toEvent());
        log.debug("Event {} for {} {} (tenant {}) matched {} channel(s)",
                request.event(), request.targetType(), request.targetId(),
                request.tenantId(), queued);
        return Map.of("queued", queued);
    }

    /**
     * Batch variant for the schedule watchdog, which finds several missed jobs
     * in one sweep. One bad entry must not discard the rest, so each is
     * dispatched independently and failures are counted rather than thrown.
     */
    @PostMapping("/internal/events/batch")
    public Map<String, Object> events(@Valid @RequestBody List<RunEventRequest> requests) {
        if (requests.size() > MAX_BATCH) {
            return Map.of("queued", 0, "rejected", requests.size(),
                    "error", "batch_too_large");
        }
        int queued = 0;
        int failed = 0;
        for (RunEventRequest request : requests) {
            try {
                queued += dispatchService.dispatch(request.toEvent());
            } catch (Exception ex) {
                failed++;
                log.warn("Could not dispatch {} for tenant {}: {}",
                        request.event(), request.tenantId(), ex.getMessage());
            }
        }
        return Map.of("queued", queued, "failed", failed);
    }
}
