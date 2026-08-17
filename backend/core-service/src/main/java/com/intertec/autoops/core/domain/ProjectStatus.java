package com.intertec.autoops.core.domain;

/**
 * ARCHIVED projects stop counting toward MAX_PROJECTS (archive frees quota;
 * restore re-checks it) but are never deleted — data always survives.
 */
public enum ProjectStatus {
    ACTIVE,
    ARCHIVED
}
