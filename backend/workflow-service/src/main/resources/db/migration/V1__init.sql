-- ============================================================
-- workflow-service owns automation workflow DEFINITIONS.
--
-- The table is the one that used to live in autoops_core (core-service
-- V1__init.sql). It moved here whole, columns unchanged, so an existing
-- deployment can copy its rows across without a transformation:
--
--   INSERT INTO autoops_workflow.workflows
--   SELECT * FROM autoops_core.workflows;
--
-- project_id keeps NO foreign key any more: projects live in another
-- service's database, so the reference is validated over core-service's
-- /internal API on every write instead of by the engine. That is the real
-- cost of the split, and it is why WorkflowService refuses to create a
-- workflow when the project check does not come back clean.
-- ============================================================

CREATE TABLE workflows (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id   VARCHAR(64)     NOT NULL,
    project_id  BIGINT UNSIGNED NOT NULL,   -- core-service project, no FK across DBs
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
    KEY idx_workflows_tenant (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
