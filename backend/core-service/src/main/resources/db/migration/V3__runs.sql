-- ============================================================
-- Execution engine: one row per run of a job or workflow. The target's
-- name and definition are SNAPSHOTTED onto the run so history stays
-- meaningful after the definition is edited or deleted (hence no FK to
-- jobs/workflows, and none to projects either — history outlives everything).
-- Reads are retention-bounded by the plan's history_days at query time.
-- ============================================================

CREATE TABLE runs (
    id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id        VARCHAR(64)     NOT NULL,
    project_id       BIGINT UNSIGNED NOT NULL,
    target_type      ENUM('JOB','WORKFLOW') NOT NULL,
    target_id        BIGINT UNSIGNED NOT NULL,
    target_name      VARCHAR(128)    NOT NULL,      -- snapshot: survives renames/deletes
    definition       MEDIUMTEXT      NULL,          -- snapshot of the steps/nodes JSON that ran
    status           ENUM('QUEUED','RUNNING','SUCCEEDED','FAILED','CANCELED') NOT NULL DEFAULT 'QUEUED',
    trigger_type     ENUM('MANUAL','SCHEDULE') NOT NULL DEFAULT 'MANUAL',
    triggered_by     VARCHAR(255)    NULL,          -- JWT subject, or "scheduler"
    step_total       INT UNSIGNED    NOT NULL DEFAULT 0,
    step_completed   INT UNSIGNED    NOT NULL DEFAULT 0,
    cancel_requested TINYINT(1)      NOT NULL DEFAULT 0,
    log              MEDIUMTEXT      NULL,
    error            VARCHAR(512)    NULL,
    started_at       TIMESTAMP(6)    NULL,
    finished_at      TIMESTAMP(6)    NULL,
    duration_ms      BIGINT UNSIGNED NULL,
    created_at       TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_runs_tenant_project_created (tenant_id, project_id, created_at),
    KEY idx_runs_target (target_type, target_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Scheduler bookkeeping: next fire time computed from the job's cron schedule
-- whenever the schedule/enabled flag changes; the poller claims due rows.
ALTER TABLE jobs
    ADD COLUMN next_run_at TIMESTAMP(6) NULL AFTER schedule,
    ADD KEY idx_jobs_due (enabled, next_run_at);