package com.intertec.autoops.plugin.domain;

/**
 * What a notification rule watches. Mirrors core-service's
 * {@code RunTargetType} — jobs and workflows share one run engine, so they
 * share one event vocabulary here too.
 */
public enum TargetType {
    JOB,
    WORKFLOW
}
