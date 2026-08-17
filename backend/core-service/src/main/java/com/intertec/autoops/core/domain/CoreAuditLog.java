package com.intertec.autoops.core.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

/** One immutable audit row — written once, never updated. */
@Entity
@Table(name = "core_audit_log")
public class CoreAuditLog {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Enumerated(EnumType.STRING)
    @Column(name = "event_type", nullable = false, columnDefinition =
            "ENUM('PROJECT_CREATED','PROJECT_UPDATED','PROJECT_ARCHIVED','PROJECT_RESTORED',"
                    + "'WORKFLOW_CREATED','WORKFLOW_UPDATED','WORKFLOW_DELETED',"
                    + "'WORKFLOW_ENABLED','WORKFLOW_DISABLED',"
                    + "'JOB_CREATED','JOB_UPDATED','JOB_DELETED',"
                    + "'AGENT_CREATED','AGENT_UPDATED','AGENT_DELETED',"
                    + "'AGENT_ENABLED','AGENT_DISABLED',"
                    + "'RUN_TRIGGERED','RUN_CANCELED',"
                    + "'APPROVAL_REQUESTED','APPROVAL_APPROVED','APPROVAL_REJECTED',"
                    + "'CONNECTION_CREATED','CONNECTION_CREDENTIALS_UPDATED',"
                    + "'CONNECTION_VERIFIED','CONNECTION_DISCONNECTED','CONNECTION_ASSIGNED',"
                    + "'CONNECTION_CLAIM_REJECTED','CONNECTION_QUARANTINED',"
                    + "'SCM_CONFIGURED','SCM_EXPORTED','SCM_IMPORTED',"
                    + "'APPROVAL_SETTINGS_UPDATED','GOVERNANCE_POLICY_UPDATED',"
                    + "'COMPLIANCE_REPORT_GENERATED',"
                    + "'SECRET_CREATED','SECRET_UPDATED','SECRET_DELETED',"
                    + "'WEBHOOK_CREATED','WEBHOOK_UPDATED','WEBHOOK_DELETED',"
                    + "'COMMAND_DISPATCHED','CONNECTOR_CREATED','CONNECTOR_DELETED',"
                    + "'LIBRARY_CREATED','LIBRARY_CLONED','BROADCAST_SENT',"
                    + "'TEMPLATE_ROLLED_OUT','TEMPLATE_REVOKED',"
                    + "'MODEL_PROVIDER_CREATED','MODEL_PROVIDER_UPDATED',"
                    + "'MODEL_PROVIDER_DELETED','MODEL_PROVIDER_VERIFIED')")
    private CoreAuditEventType eventType;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Column(name = "project_id")
    private Long projectId;

    @Column(name = "target_type", length = 32)
    private String targetType;

    @Column(name = "target_id", length = 64)
    private String targetId;

    @Column(name = "target_name", length = 255)
    private String targetName;

    @Column(length = 255)
    private String actor;

    @Column(length = 1024)
    private String detail;

    /** Set in code (like Run.createdAt) so H2 tests get a value too. */
    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt = Instant.now();

    public Long getId() {
        return id;
    }

    public CoreAuditEventType getEventType() {
        return eventType;
    }

    public void setEventType(CoreAuditEventType eventType) {
        this.eventType = eventType;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public Long getProjectId() {
        return projectId;
    }

    public void setProjectId(Long projectId) {
        this.projectId = projectId;
    }

    public String getTargetType() {
        return targetType;
    }

    public void setTargetType(String targetType) {
        this.targetType = targetType;
    }

    public String getTargetId() {
        return targetId;
    }

    public void setTargetId(String targetId) {
        this.targetId = targetId;
    }

    public String getTargetName() {
        return targetName;
    }

    public void setTargetName(String targetName) {
        this.targetName = targetName;
    }

    public String getActor() {
        return actor;
    }

    public void setActor(String actor) {
        this.actor = actor;
    }

    public String getDetail() {
        return detail;
    }

    public void setDetail(String detail) {
        this.detail = detail;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }
}
