-- ============================================================
-- Jobs (project-scoped step pipelines) and cloud connections (tenant-scoped
-- integrations). Both are plan-limited: MAX_JOBS / MAX_CLOUD_INTEGRATIONS
-- via the central entitlement check. Execution/run history is a later
-- engine — these are the definitions.
-- ============================================================

CREATE TABLE jobs (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id   VARCHAR(64)     NOT NULL,
    project_id  BIGINT UNSIGNED NOT NULL,
    name        VARCHAR(128)    NOT NULL,
    job_group   VARCHAR(64)     NULL,           -- folder-style grouping ("database/cleanup")
    description VARCHAR(255)    NULL,
    definition  MEDIUMTEXT      NULL,           -- steps JSON {"steps":[{type,label,category}]}
    step_count  INT UNSIGNED    NOT NULL DEFAULT 0,  -- counted server-side
    schedule    VARCHAR(64)     NULL,           -- cron; unused until a scheduler exists
    enabled     TINYINT(1)      NOT NULL DEFAULT 1,
    created_by  VARCHAR(255)    NULL,
    created_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_jobs_project_name (project_id, name),
    KEY idx_jobs_tenant (tenant_id),
    CONSTRAINT fk_job_project FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE cloud_connections (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id   VARCHAR(64)     NOT NULL,
    platform    ENUM('AWS','AZURE','GCP','HUAWEI','ORACLE','M365') NOT NULL,
    name        VARCHAR(128)    NOT NULL,
    status      ENUM('CONNECTED','DISCONNECTED') NOT NULL DEFAULT 'CONNECTED',
    created_by  VARCHAR(255)    NULL,
    created_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_cloud_tenant_name (tenant_id, name),
    KEY idx_cloud_tenant (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
