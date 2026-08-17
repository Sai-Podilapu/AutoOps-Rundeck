package com.intertec.autoops.core.domain;

/** Lifecycle of a run: QUEUED → RUNNING → SUCCEEDED | FAILED | CANCELED. */
public enum RunStatus {
    QUEUED, RUNNING, SUCCEEDED, FAILED, CANCELED;

    /** Terminal states never change again. */
    public boolean isTerminal() {
        return this == SUCCEEDED || this == FAILED || this == CANCELED;
    }
}