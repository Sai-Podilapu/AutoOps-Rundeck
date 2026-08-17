package com.intertec.autoops.core.domain;

/**
 * How a run was started: the Run button, the cron scheduler, an inbound
 * webhook, or an agent acting on its own allow-list.
 */
public enum RunTrigger {
    MANUAL, SCHEDULE, WEBHOOK, AGENT
}