-- ============================================================
-- V2 — Rundeck becomes THE execution engine, white-labelled.
--
-- V1 modelled a tenant connecting their OWN Rundeck. The product model changed:
-- AutoOps runs one Rundeck itself, its URL and admin token come from the
-- environment (never a database row a tenant could reach), and every job in
-- every project in every tenant executes on it.
--
-- rundeck_connections is therefore gone. It is DROPPED rather than left in
-- place: a table that no code reads is a table someone eventually writes to,
-- and this one held encrypted credentials for third-party servers. Leaving it
-- would mean a dormant credential store with no owner.
--
-- ‼️ This drops customer-entered Rundeck API tokens if any were saved on this
-- branch. They cannot be recovered from a backup of another environment,
-- because RUNDECK_CRED_KEY is per-deployment. Re-entering a token is the fix;
-- there is nothing else in the table.
-- ============================================================

DROP TABLE IF EXISTS rundeck_connections;


-- The isolation boundary.
--
-- One shared Rundeck serving every tenant means the credential is no longer
-- what separates customers — a Rundeck PROJECT is. Each AutoOps project gets
-- exactly one, named `{prefix}-{tenant}-{projectId}` and derived server-side
-- from the JWT tenant claim. The name is NEVER taken from a request: accepting
-- one would let a caller address another workspace's project by typing its
-- name, which is precisely the boundary this table exists to hold.
--
-- The unique key on rundeck_project is what makes that structural rather than
-- conventional: two AutoOps projects cannot map onto one Rundeck project even
-- if the naming function is ever changed carelessly.
CREATE TABLE rundeck_projects (
    id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id       VARCHAR(64)     NOT NULL,
    project_id      BIGINT UNSIGNED NOT NULL,   -- core-service project, no FK across DBs
    rundeck_project VARCHAR(255)    NOT NULL,   -- autoops-<tenant>-<projectId>
    -- Provisioning is idempotent and lazy (first step run in a project creates
    -- it). This records that Rundeck confirmed it, so the common path is a
    -- single indexed read rather than an API call per step.
    provisioned     TINYINT(1)      NOT NULL DEFAULT 0,
    last_error      VARCHAR(512)    NULL,
    created_at      TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at      TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                    ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_rundeck_project_scope (tenant_id, project_id),
    UNIQUE KEY uq_rundeck_project_name (rundeck_project)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_0900_ai_ci;


-- rundeck_dispatches survives from V1 but its shape changes: a dispatch is now
-- one STEP of an AutoOps run rather than a whole Rundeck job someone browsed
-- to and pressed Run on. connection_id is meaningless with a single platform
-- server, and the AutoOps run/step it belongs to is what an auditor actually
-- asks about.
ALTER TABLE rundeck_dispatches
    DROP COLUMN connection_id,
    ADD COLUMN run_id      BIGINT UNSIGNED NULL AFTER tenant_id,
    ADD COLUMN step_index  INT             NULL AFTER run_id,
    ADD COLUMN step_type   VARCHAR(32)     NULL AFTER step_index,
    ADD KEY idx_dispatch_run (tenant_id, run_id);

-- job_id held a Rundeck job UUID in V1. Ad-hoc step execution has no job, so
-- the column becomes nullable rather than carrying a placeholder that looks
-- like an id.
ALTER TABLE rundeck_dispatches
    MODIFY COLUMN job_id VARCHAR(64) NULL;
