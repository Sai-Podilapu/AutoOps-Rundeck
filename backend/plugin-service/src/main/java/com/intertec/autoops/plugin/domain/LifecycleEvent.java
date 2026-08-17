package com.intertec.autoops.plugin.domain;

/**
 * The lifecycle moments a tenant can be notified about.
 *
 * <p>The first five mirror core-service's {@code RunStatus} transitions
 * exactly — including the single-L {@code CANCELED} spelling, which is what
 * that enum uses. Do not "fix" it here; the two must line up or the mapping
 * in {@code RunEventRequest} silently drops events.
 *
 * <p>{@link #MISSED} and {@link #STALLED} have no equivalent status because
 * they describe a run that did <em>not</em> happen or has not ended. They are
 * emitted by core-service's schedule watchdog rather than by the run engine.
 */
public enum LifecycleEvent {

    /** Accepted by the scheduler or an API call; no step has run yet. */
    QUEUED(Severity.INFO),

    /** The run engine picked it up — status moved to RUNNING. */
    STARTED(Severity.INFO),

    /** Every step finished cleanly. */
    SUCCEEDED(Severity.INFO),

    /** A step failed, or the engine crashed mid-run. */
    FAILED(Severity.CRITICAL),

    /** Stopped by a user or by shutdown. Core spells it with one L. */
    CANCELED(Severity.WARNING),

    /**
     * A scheduled window elapsed and nothing ran — the "not running" case.
     * Distinct from FAILED: nothing was attempted, so there is no run to open.
     */
    MISSED(Severity.CRITICAL),

    /** Still RUNNING well past its expected duration. */
    STALLED(Severity.WARNING),

    /** First success after one or more consecutive failures. */
    RECOVERED(Severity.INFO);

    private final Severity severity;

    LifecycleEvent(Severity severity) {
        this.severity = severity;
    }

    public Severity severity() {
        return severity;
    }

    /** True for the events that end a run, whatever the outcome. */
    public boolean isTerminal() {
        return this == SUCCEEDED || this == FAILED || this == CANCELED || this == RECOVERED;
    }

    /** Drives colour and icon in every channel that renders one. */
    public enum Severity {
        INFO,
        WARNING,
        CRITICAL
    }
}
