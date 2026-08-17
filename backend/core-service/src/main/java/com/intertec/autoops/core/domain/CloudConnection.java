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
 * A tenant's connected cloud/integration account, gated by the plan's
 * MAX_CLOUD_INTEGRATIONS. Credentials (when provided) are stored encrypted
 * and only ever decrypted to hand to the execution runtime — never returned
 * by the API.
 */
@Entity
@Table(name = "cloud_connections")
public class CloudConnection {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition =
            "ENUM('AWS','AZURE','GCP','HUAWEI','ORACLE','M365','KUBERNETES')")
    private CloudPlatform platform;

    @Column(nullable = false, length = 128)
    private String name;

    /** Scopes the connection to one project; null = global (all projects). */
    @Column(name = "project_id")
    private Long projectId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition = "ENUM('CONNECTED','DISCONNECTED')")
    private ConnectionStatus status = ConnectionStatus.CONNECTED;

    /** AES-GCM ciphertext of the credentials JSON; null = record only. */
    @Column(name = "credentials_enc", columnDefinition = "TEXT")
    private String credentialsEnc;

    /** Outcome of the last live provider verification; null = never checked. */
    @Column(name = "last_verified_at")
    private Instant lastVerifiedAt;

    @Column(name = "last_verified_ok")
    private Boolean lastVerifiedOk;

    @Column(name = "last_verified_message", length = 512)
    private String lastVerifiedMessage;

    /** Identity the provider itself reported at the last verification. */
    @Column(name = "verified_account_id", length = 128)
    private String verifiedAccountId;

    @Column(name = "verified_account_name", length = 256)
    private String verifiedAccountName;

    public String getVerifiedAccountId() {
        return verifiedAccountId;
    }

    public void setVerifiedAccountId(String verifiedAccountId) {
        this.verifiedAccountId = verifiedAccountId;
    }

    public String getVerifiedAccountName() {
        return verifiedAccountName;
    }

    public void setVerifiedAccountName(String verifiedAccountName) {
        this.verifiedAccountName = verifiedAccountName;
    }

    public String getCredentialsEnc() {
        return credentialsEnc;
    }

    public void setCredentialsEnc(String credentialsEnc) {
        this.credentialsEnc = credentialsEnc;
    }

    public Instant getLastVerifiedAt() {
        return lastVerifiedAt;
    }

    public void setLastVerifiedAt(Instant lastVerifiedAt) {
        this.lastVerifiedAt = lastVerifiedAt;
    }

    public Boolean getLastVerifiedOk() {
        return lastVerifiedOk;
    }

    public void setLastVerifiedOk(Boolean lastVerifiedOk) {
        this.lastVerifiedOk = lastVerifiedOk;
    }

    public String getLastVerifiedMessage() {
        return lastVerifiedMessage;
    }

    public void setLastVerifiedMessage(String lastVerifiedMessage) {
        this.lastVerifiedMessage = lastVerifiedMessage;
    }

    @Column(name = "created_by", length = 255)
    private String createdBy;

    @Column(name = "created_at", insertable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", insertable = false, updatable = false)
    private Instant updatedAt;

    public CloudConnection() {
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

    public CloudPlatform getPlatform() {
        return platform;
    }

    public void setPlatform(CloudPlatform platform) {
        this.platform = platform;
    }

    public String getName() {
        return name;
    }

    public Long getProjectId() {
        return projectId;
    }

    public void setProjectId(Long projectId) {
        this.projectId = projectId;
    }

    public void setName(String name) {
        this.name = name;
    }

    public ConnectionStatus getStatus() {
        return status;
    }

    public void setStatus(ConnectionStatus status) {
        this.status = status;
    }

    public String getCreatedBy() {
        return createdBy;
    }

    public void setCreatedBy(String createdBy) {
        this.createdBy = createdBy;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    public Instant getUpdatedAt() {
        return updatedAt;
    }
}
