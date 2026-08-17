package com.intertec.autoops.core.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

/**
 * Per-tenant approval tuning: the workflow-complexity node threshold.
 * Absence of a row means the platform default applies.
 */
@Entity
@Table(name = "approval_settings")
public class ApprovalSetting {

    @Id
    @Column(name = "tenant_id", length = 64)
    private String tenantId;

    @Column(name = "complex_node_threshold", nullable = false)
    private int complexNodeThreshold;

    /** CSV; NULL = platform default set, empty = risky-type gating disabled. */
    @Column(name = "risky_types", length = 1024)
    private String riskyTypes;

    @Column(name = "updated_by", length = 255)
    private String updatedBy;

    @Column(name = "updated_at", insertable = false, updatable = false)
    private Instant updatedAt;

    public ApprovalSetting() {
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public int getComplexNodeThreshold() {
        return complexNodeThreshold;
    }

    public void setComplexNodeThreshold(int complexNodeThreshold) {
        this.complexNodeThreshold = complexNodeThreshold;
    }

    public String getRiskyTypes() {
        return riskyTypes;
    }

    public void setRiskyTypes(String riskyTypes) {
        this.riskyTypes = riskyTypes;
    }

    public String getUpdatedBy() {
        return updatedBy;
    }

    public void setUpdatedBy(String updatedBy) {
        this.updatedBy = updatedBy;
    }

    public Instant getUpdatedAt() {
        return updatedAt;
    }
}