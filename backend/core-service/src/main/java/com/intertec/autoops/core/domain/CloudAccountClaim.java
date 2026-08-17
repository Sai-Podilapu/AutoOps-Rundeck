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
 * One tenant's exclusive hold on one cloud account. The unique key
 * (platform, kind, fingerprint) is what makes a cloud account usable by a
 * single tenant only — see V21__cloud_account_claims.sql.
 *
 * <p>{@code fingerprint} is a keyed hash (HMAC-SHA256 under CLOUD_CRED_KEY) of
 * the identifying value; the value itself is never stored, so this table
 * cannot be read back into a list of customer account numbers.
 */
@Entity
@Table(name = "cloud_account_claims")
public class CloudAccountClaim {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition =
            "ENUM('AWS','AZURE','GCP','HUAWEI','ORACLE','M365','KUBERNETES')")
    private CloudPlatform platform;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition = "ENUM('ACCOUNT','CREDENTIAL')")
    private CloudAccountClaimKind kind;

    // CHAR, not VARCHAR: every fingerprint is exactly one 64-char hex digest.
    // Must match V21's DDL or Hibernate's schema validation refuses to boot.
    @Column(nullable = false, columnDefinition = "CHAR(64)")
    private String fingerprint;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    /** The connection that first claimed it — support context, not ownership. */
    @Column(name = "connection_id")
    private Long connectionId;

    @Column(name = "created_at", insertable = false, updatable = false)
    private Instant createdAt;

    public CloudAccountClaim() {
    }

    public CloudAccountClaim(CloudPlatform platform, CloudAccountClaimKind kind,
                             String fingerprint, String tenantId, Long connectionId) {
        this.platform = platform;
        this.kind = kind;
        this.fingerprint = fingerprint;
        this.tenantId = tenantId;
        this.connectionId = connectionId;
    }

    public Long getId() {
        return id;
    }

    public CloudPlatform getPlatform() {
        return platform;
    }

    public void setPlatform(CloudPlatform platform) {
        this.platform = platform;
    }

    public CloudAccountClaimKind getKind() {
        return kind;
    }

    public void setKind(CloudAccountClaimKind kind) {
        this.kind = kind;
    }

    public String getFingerprint() {
        return fingerprint;
    }

    public void setFingerprint(String fingerprint) {
        this.fingerprint = fingerprint;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public Long getConnectionId() {
        return connectionId;
    }

    public void setConnectionId(Long connectionId) {
        this.connectionId = connectionId;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }
}