-- ============================================================
-- AutoOps core-service — MySQL schema (database: autoops_core)
-- Managed by Flyway. spring.jpa.hibernate.ddl-auto = validate
-- TYPE POLICY: closed value sets are strict MySQL ENUMs (same convention as
-- auth-service); extending one = ALTER ... MODIFY migration + Java enum constant.
-- Tenant model: every row carries tenant_id (from the JWT claim, never a
-- header); all queries are tenant-scoped.
-- ============================================================

CREATE TABLE projects (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id   VARCHAR(64)     NOT NULL,
    name        VARCHAR(128)    NOT NULL,
    description VARCHAR(255)    NULL,
    status      ENUM('ACTIVE','ARCHIVED') NOT NULL DEFAULT 'ACTIVE',
    created_by  VARCHAR(255)    NULL,           -- JWT subject (email)
    created_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_projects_tenant (tenant_id, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE workflows (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id   VARCHAR(64)     NOT NULL,
    project_id  BIGINT UNSIGNED NOT NULL,
    name        VARCHAR(128)    NOT NULL,
    definition  MEDIUMTEXT      NULL,           -- canvas JSON {"nodes":[...],"edges":[...]}
    node_count  INT UNSIGNED    NOT NULL DEFAULT 0,  -- counted server-side, gated by MAX_NODES
    enabled     TINYINT(1)      NOT NULL DEFAULT 1,
    created_by  VARCHAR(255)    NULL,
    created_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_workflows_project_name (project_id, name),
    KEY idx_workflows_tenant (tenant_id),
    CONSTRAINT fk_wf_project FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
