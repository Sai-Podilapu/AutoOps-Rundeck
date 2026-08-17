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

/**
 * A tenant's stored mode for one CONFIGURABLE governance policy
 * (SCM_REQUIRED / FAILURE_BUDGET / APPROVAL_SLA). No row = the policy's
 * platform default. The policy key is a plain string column mirroring the
 * MySQL ENUM — the catalog itself lives in GovernanceService.
 */
@Entity
@Table(name = "governance_policies")
public class GovernancePolicySetting {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Column(nullable = false,
            columnDefinition = "ENUM('SCM_REQUIRED','FAILURE_BUDGET','APPROVAL_SLA')")
    private String policy;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition = "ENUM('ENFORCED','MONITOR','DISABLED')")
    private GovernancePolicyMode mode;

    @Column(name = "updated_by", length = 255)
    private String updatedBy;

    @Column(name = "updated_at", insertable = false, updatable = false)
    private Instant updatedAt;

    public GovernancePolicySetting() {
    }

    public Long getId() {
        return id;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public String getPolicy() {
        return policy;
    }

    public void setPolicy(String policy) {
        this.policy = policy;
    }

    public GovernancePolicyMode getMode() {
        return mode;
    }

    public void setMode(GovernancePolicyMode mode) {
        this.mode = mode;
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