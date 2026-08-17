-- ============================================================
-- Core audit trail — attributed record of every tenant-facing mutation
-- (same convention as auth_audit_log / subscription_audit_log: strict ENUM
-- event types, DB-managed created_at, rows never updated). No FK to the
-- target — audit must survive deletes, so target name is snapshotted.
-- Reading the log is an AUDIT_LOG plan feature (Team+); writing is
-- unconditional — compliance evidence does not depend on the plan.
-- ============================================================

CREATE TABLE core_audit_log (
    id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    event_type   ENUM('PROJECT_CREATED','PROJECT_UPDATED','PROJECT_ARCHIVED','PROJECT_RESTORED',
                      'WORKFLOW_CREATED','WORKFLOW_UPDATED','WORKFLOW_DELETED',
                      'WORKFLOW_ENABLED','WORKFLOW_DISABLED',
                      'JOB_CREATED','JOB_UPDATED','JOB_DELETED',
                      'RUN_TRIGGERED','RUN_CANCELED',
                      'APPROVAL_REQUESTED','APPROVAL_APPROVED','APPROVAL_REJECTED',
                      'CONNECTION_CREATED','CONNECTION_CREDENTIALS_UPDATED',
                      'CONNECTION_VERIFIED','CONNECTION_DISCONNECTED',
                      'SCM_CONFIGURED','SCM_EXPORTED','SCM_IMPORTED',
                      'APPROVAL_SETTINGS_UPDATED','GOVERNANCE_POLICY_UPDATED',
                      'COMPLIANCE_REPORT_GENERATED') NOT NULL,
    tenant_id    VARCHAR(64)     NOT NULL,
    project_id   BIGINT UNSIGNED NULL,          -- context, no FK
    target_type  VARCHAR(32)     NULL,          -- PROJECT|WORKFLOW|JOB|RUN|CONNECTION|...
    target_id    VARCHAR(64)     NULL,
    target_name  VARCHAR(255)    NULL,          -- snapshotted at event time
    actor        VARCHAR(255)    NULL,          -- JWT subject; null for the scheduler
    detail       VARCHAR(1024)   NULL,          -- free text; must never contain secrets
    created_at   TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_core_audit_tenant (tenant_id, created_at),
    KEY idx_core_audit_project (tenant_id, project_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
