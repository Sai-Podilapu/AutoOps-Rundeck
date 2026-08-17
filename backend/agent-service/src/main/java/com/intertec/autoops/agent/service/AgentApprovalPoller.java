package com.intertec.autoops.agent.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Chases the verdicts on runs parked in AWAITING_APPROVAL.
 *
 * <p>A poller rather than a callback, for two reasons. core-service has no way
 * to reach a specific paused loop — it would have to know which instance holds
 * it, which is only true while there is exactly one. And a run parked before
 * the last restart has no loop to call back into at all; only something that
 * re-reads the table can pick that up.
 *
 * <p>Fifteen seconds is chosen against the human on the other side: an admin
 * who clicks Approve expects the agent to move within a few seconds, and
 * nobody notices fifteen. A parked run costs one internal GET per tick, and
 * runs parked on a human are rare by construction.
 */
@Component
public class AgentApprovalPoller {

    private static final Logger log = LoggerFactory.getLogger(AgentApprovalPoller.class);

    private final AgentRunService runService;

    public AgentApprovalPoller(AgentRunService runService) {
        this.runService = runService;
    }

    @Scheduled(fixedDelayString = "${autoops.agent.loop.approval-poll-interval:15s}")
    public void poll() {
        try {
            runService.resumeApproved();
        } catch (RuntimeException ex) {
            // Never let one bad row stop the schedule: the next tick must
            // still run, or every parked run in the service stays parked.
            log.warn("Approval poll failed; will retry on the next tick: {}", ex.getMessage());
        }
    }
}
