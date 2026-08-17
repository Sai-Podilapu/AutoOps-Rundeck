-- ============================================================
-- Per-project SCM (git) sync config. The access token is encrypted at
-- rest with the same AES-GCM key as cloud credentials. One config per
-- project; export writes jobs/workflows as JSON files under base_path,
-- import upserts them back (OVERWRITE or SKIP strategy).
-- ============================================================

CREATE TABLE scm_configs (
    project_id BIGINT UNSIGNED NOT NULL,
    tenant_id  VARCHAR(64)     NOT NULL,
    repo_url   VARCHAR(512)    NOT NULL,
    branch     VARCHAR(128)    NOT NULL DEFAULT 'main',
    base_path  VARCHAR(256)    NOT NULL DEFAULT '',
    username   VARCHAR(128)    NULL,
    token_enc  TEXT            NULL,
    updated_by VARCHAR(255)    NULL,
    updated_at TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
               ON UPDATE CURRENT_TIMESTAMP(6),
    created_at TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (project_id),
    KEY idx_scm_tenant (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
