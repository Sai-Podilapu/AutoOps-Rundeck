-- ============================================================
-- Human approval gate. A job flagged requires_approval cannot be run
-- manually by a non-admin: the run request becomes a PENDING approval
-- row instead, and an ADMIN approves (which starts the run) or rejects.
-- Admin-triggered manual runs and cron-scheduled runs are not gated.
-- job_name is SNAPSHOTTED (no FK) so the approval trail survives job
-- deletion, mirroring runs.
-- ============================================================

ALTER TABLE jobs
    ADD COLUMN requires_approval TINYINT(1) NOT NULL DEFAULT 0 AFTER enabled;

CREATE TABLE approvals (
    id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id    VARCHAR(64)     NOT NULL,
    project_id   BIGINT UNSIGNED NOT NULL,
    job_id       BIGINT UNSIGNED NOT NULL,
    job_name     VARCHAR(128)    NOT NULL,      -- snapshot: survives renames/deletes
    requested_by VARCHAR(255)    NOT NULL,      -- JWT subject of the requester
    status       ENUM('PENDING','APPROVED','REJECTED') NOT NULL DEFAULT 'PENDING',
    decided_by   VARCHAR(255)    NULL,          -- JWT subject of the deciding admin
    decided_at   TIMESTAMP(6)    NULL,
    run_id       BIGINT UNSIGNED NULL,          -- run started by the approval
    created_at   TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_approvals_tenant_created (tenant_id, created_at),
    KEY idx_approvals_job_status (job_id, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;