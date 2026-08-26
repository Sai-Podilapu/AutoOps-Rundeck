-- ============================================================
-- An AutoOps job's counterpart ON the platform engine.
--
-- Until now a job lived only in autoops_core.jobs and each of its steps was
-- dispatched ad-hoc at run time, so Rundeck's own JOBS screen was permanently
-- empty and its scheduler never held anything. This table is the seam that
-- changes that: one row per (tenant, AutoOps job) that has been imported into
-- Rundeck as a real job definition.
--
-- WHAT THIS IS NOT: a copy of the job. The definition still belongs to
-- core-service — the same reasoning as rundeck_connections' header. All that
-- is recorded here is the identity of the engine-side object and whether the
-- last import succeeded, so a failed sync is visible rather than silent.
-- ============================================================

CREATE TABLE rundeck_jobs (
    id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id         VARCHAR(64)     NOT NULL,
    -- The AutoOps project this job belongs to. Carried so a project archive can
    -- find every job it must remove from the engine without asking core-service.
    project_id        BIGINT UNSIGNED NOT NULL,
    -- autoops_core.jobs.id. Not a foreign key: that table is in another
    -- service's schema, and a cross-schema constraint would couple their
    -- migrations forever.
    autoops_job_id    BIGINT UNSIGNED NOT NULL,

    -- The Rundeck project the job was imported into.
    rundeck_project   VARCHAR(255)    NOT NULL,
    -- Rundeck's job UUID. DERIVED from (tenant, autoops_job_id) rather than
    -- returned by Rundeck, so a re-import updates the same job instead of
    -- creating a duplicate, and so the link is recoverable if this row is lost.
    -- VARCHAR, not CHAR: the entity maps this as a String, and Hibernate's
    -- schema validation rejects CHAR against it outright ("found [char],
    -- but expecting [varchar(36)]"), refusing to start the service.
    rundeck_job_uuid  VARCHAR(36)     NOT NULL,

    -- False when the last import failed. The job still exists in AutoOps and
    -- can still be edited; it simply is not on the engine yet.
    imported          TINYINT(1)      NOT NULL DEFAULT 0,
    -- Why the last import failed, truncated. NULL on success.
    last_error        VARCHAR(512)    NULL,

    -- Whether the ENGINE currently owns this job's schedule. Recorded rather
    -- than inferred because it is the thing that decides double-execution: for
    -- as long as core-service's JobScheduler also fires this job, the engine's
    -- scheduler must stay off, or every scheduled run happens twice.
    schedule_owned_by_engine TINYINT(1) NOT NULL DEFAULT 0,

    created_at        TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at        TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

    PRIMARY KEY (id),

    -- One engine job per AutoOps job. Without this, a retried import that raced
    -- itself would leave two rows pointing at one Rundeck job and the second
    -- delete would 404 forever.
    UNIQUE KEY uq_rundeck_jobs_autoops (tenant_id, autoops_job_id),

    -- The same guarantee from the engine's side. The UUID is derived, so two
    -- rows sharing one means the derivation collided — which must fail loudly
    -- here rather than silently overwrite a tenant's job on the engine.
    UNIQUE KEY uq_rundeck_jobs_uuid (rundeck_job_uuid),

    KEY idx_rundeck_jobs_project (tenant_id, project_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
