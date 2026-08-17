-- ============================================================
-- Agent events join core-service's audit trail.
--
-- The agents TABLE itself lives in agent-service (autoops_agent), but the
-- audit trail stays single: agent-service posts its events to core-service's
-- /internal/audit, so the console's Audit page still answers "who changed
-- what in this project" from one table.
--
-- Extending the ENUM is therefore the whole of what core-service needs to
-- know about agents.
-- ============================================================

ALTER TABLE core_audit_log
    MODIFY event_type ENUM('PROJECT_CREATED','PROJECT_UPDATED','PROJECT_ARCHIVED','PROJECT_RESTORED',
                      'WORKFLOW_CREATED','WORKFLOW_UPDATED','WORKFLOW_DELETED',
                      'WORKFLOW_ENABLED','WORKFLOW_DISABLED',
                      'JOB_CREATED','JOB_UPDATED','JOB_DELETED',
                      'AGENT_CREATED','AGENT_UPDATED','AGENT_DELETED',
                      'AGENT_ENABLED','AGENT_DISABLED',
                      'RUN_TRIGGERED','RUN_CANCELED',
                      'APPROVAL_REQUESTED','APPROVAL_APPROVED','APPROVAL_REJECTED',
                      'CONNECTION_CREATED','CONNECTION_CREDENTIALS_UPDATED',
                      'CONNECTION_VERIFIED','CONNECTION_DISCONNECTED','CONNECTION_ASSIGNED',
                      'CONNECTION_CLAIM_REJECTED','CONNECTION_QUARANTINED',
                      'SCM_CONFIGURED','SCM_EXPORTED','SCM_IMPORTED',
                      'APPROVAL_SETTINGS_UPDATED','GOVERNANCE_POLICY_UPDATED',
                      'COMPLIANCE_REPORT_GENERATED',
                      'SECRET_CREATED','SECRET_UPDATED','SECRET_DELETED',
                      'WEBHOOK_CREATED','WEBHOOK_UPDATED','WEBHOOK_DELETED',
                      'COMMAND_DISPATCHED',
                      'CONNECTOR_CREATED','CONNECTOR_DELETED',
                      'LIBRARY_CREATED','LIBRARY_CLONED',
                      'BROADCAST_SENT') NOT NULL;
