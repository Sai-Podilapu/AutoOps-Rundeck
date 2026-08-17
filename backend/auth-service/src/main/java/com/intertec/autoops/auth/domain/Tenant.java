package com.intertec.autoops.auth.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

/** A workspace's human-readable identity (the tenant_id itself is a slug). */
@Entity
@Table(name = "tenants")
public class Tenant {

    @Id
    @Column(name = "tenant_id", length = 64)
    private String tenantId;

    @Column(name = "display_name", nullable = false, length = 128)
    private String displayName;

    /**
     * Corporate email domain this organization has claimed (globally unique);
     * null for free-provider workspaces and pre-claim tenants. Set only once
     * an admin with a VERIFIED email at that domain exists.
     */
    @Column(name = "email_domain", length = 255)
    private String emailDomain;

    @Column(name = "created_at", insertable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", insertable = false, updatable = false)
    private Instant updatedAt;

    public Tenant() {
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public String getDisplayName() {
        return displayName;
    }

    public void setDisplayName(String displayName) {
        this.displayName = displayName;
    }

    public String getEmailDomain() {
        return emailDomain;
    }

    public void setEmailDomain(String emailDomain) {
        this.emailDomain = emailDomain;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    public Instant getUpdatedAt() {
        return updatedAt;
    }
}
