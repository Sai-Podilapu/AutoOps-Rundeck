-- ============================================================
-- Rolling a catalog workflow or agent out to a customer, and withdrawing one,
-- are provider actions against a TENANT's workspace — so they are written to
-- that tenant's audit log, not only the provider's. A customer must be able
-- to see, in their own trail, when an automation appeared in their workspace
-- and who put it there.
-- ============================================================

ALTER TABLE core_audit_log
    MODIFY event_type ENUM('PROJECT_CREATED','PROJECT_UPDATED','PROJECT_ARCHIVED','PROJECT_RESTORED',
                      'WORKFLOW_CREATED','WORKFLOW_UPDATED','WORKFLOW_DELETED',
                      'WORKFLOW_ENABLED','WORKFLOW_DISABLED',
                      'JOB_CREATED','JOB_UPDATED','JOB_DELETED',
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
                      'BROADCAST_SENT',
                      'TEMPLATE_ROLLED_OUT','TEMPLATE_REVOKED') NOT NULL;
