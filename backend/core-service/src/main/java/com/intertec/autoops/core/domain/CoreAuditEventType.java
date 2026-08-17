package com.intertec.autoops.core.domain;

/**
 * Closed set of auditable core events — extending it = ALTER the
 * {@code core_audit_log.event_type} ENUM in a migration + a constant here
 * (same policy as the other services' audit ENUMs).
 */
public enum CoreAuditEventType {
    PROJECT_CREATED,
    PROJECT_UPDATED,
    PROJECT_ARCHIVED,
    PROJECT_RESTORED,
    WORKFLOW_CREATED,
    WORKFLOW_UPDATED,
    WORKFLOW_DELETED,
    WORKFLOW_ENABLED,
    WORKFLOW_DISABLED,
    JOB_CREATED,
    JOB_UPDATED,
    JOB_DELETED,
    AGENT_CREATED,
    AGENT_UPDATED,
    AGENT_DELETED,
    AGENT_ENABLED,
    AGENT_DISABLED,
    /** An agent loop started, and a human stopping one. See V34. */
    AGENT_RUN_STARTED,
    AGENT_RUN_CANCELLED,
    RUN_TRIGGERED,
    RUN_CANCELED,
    APPROVAL_REQUESTED,
    APPROVAL_APPROVED,
    APPROVAL_REJECTED,
    CONNECTION_CREATED,
    CONNECTION_CREDENTIALS_UPDATED,
    CONNECTION_VERIFIED,
    CONNECTION_DISCONNECTED,
    CONNECTION_ASSIGNED,
    /** A cloud account already claimed by another tenant was refused. */
    CONNECTION_CLAIM_REJECTED,
    /** Credentials proven to belong to another tenant's account were destroyed. */
    CONNECTION_QUARANTINED,
    SCM_CONFIGURED,
    SCM_EXPORTED,
    SCM_IMPORTED,
    APPROVAL_SETTINGS_UPDATED,
    GOVERNANCE_POLICY_UPDATED,
    COMPLIANCE_REPORT_GENERATED,
    SECRET_CREATED,
    SECRET_UPDATED,
    SECRET_DELETED,
    WEBHOOK_CREATED,
    WEBHOOK_UPDATED,
    WEBHOOK_DELETED,
    COMMAND_DISPATCHED,
    CONNECTOR_CREATED,
    CONNECTOR_DELETED,
    LIBRARY_CREATED,
    LIBRARY_CLONED,
    LIBRARY_UPDATED,
    BROADCAST_SENT,
    /** A provider delivered a catalog workflow/agent into this workspace. */
    TEMPLATE_ROLLED_OUT,
    /** A provider withdrew one it had delivered. */
    TEMPLATE_REVOKED,
    MODEL_PROVIDER_CREATED,
    MODEL_PROVIDER_UPDATED,
    MODEL_PROVIDER_DELETED,
    /** A real call against the vendor proved the stored credential works. */
    MODEL_PROVIDER_VERIFIED
}
