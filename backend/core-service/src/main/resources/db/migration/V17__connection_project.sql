-- ============================================================
-- Project assignment for cloud connections. NULL = global: the connection
-- is available to (and shown on) every project. A non-null project_id scopes
-- the connection to that one project. No hard FK (projects are soft-archived,
-- same convention as runs/approvals); a dangling assignment just hides the
-- connection from project pages until it is reassigned on the workspace page.
-- ============================================================

ALTER TABLE cloud_connections
    ADD COLUMN project_id BIGINT NULL AFTER name,
    ADD KEY idx_cloud_conn_project (project_id);

ALTER TABLE core_audit_log
    MODIFY event_type ENUM('PROJECT_CREATED','PROJECT_UPDATED','PROJECT_ARCHIVED','PROJECT_RESTORED',
                      'WORKFLOW_CREATED','WORKFLOW_UPDATED','WORKFLOW_DELETED',
                      'WORKFLOW_ENABLED','WORKFLOW_DISABLED',
                      'JOB_CREATED','JOB_UPDATED','JOB_DELETED',
                      'RUN_TRIGGERED','RUN_CANCELED',
                      'APPROVAL_REQUESTED','APPROVAL_APPROVED','APPROVAL_REJECTED',
                      'CONNECTION_CREATED','CONNECTION_CREDENTIALS_UPDATED',
                      'CONNECTION_VERIFIED','CONNECTION_DISCONNECTED','CONNECTION_ASSIGNED',
                      'SCM_CONFIGURED','SCM_EXPORTED','SCM_IMPORTED',
                      'APPROVAL_SETTINGS_UPDATED','GOVERNANCE_POLICY_UPDATED',
                      'COMPLIANCE_REPORT_GENERATED',
                      'SECRET_CREATED','SECRET_UPDATED','SECRET_DELETED',
                      'WEBHOOK_CREATED','WEBHOOK_UPDATED','WEBHOOK_DELETED',
                      'COMMAND_DISPATCHED',
                      'CONNECTOR_CREATED','CONNECTOR_DELETED',
                      'LIBRARY_CREATED','LIBRARY_CLONED',
                      'BROADCAST_SENT') NOT NULL;
