package com.intertec.autoops.plugin.domain;

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
 * One tenant's configured copy of one plugin — "the #ops-alerts Slack channel",
 * "the on-call mailbox". A tenant may install the same plugin several times
 * with different settings, which is why {@code displayName} rather than
 * {@code pluginKey} is what has to be unique within a workspace.
 *
 * <p>{@code tenantId} is on the row and every query filters by it. There is no
 * Hibernate filter and no ambient tenant in this service — deliberately, since
 * delivery runs on a worker thread where a request-scoped context would not
 * exist. The tenant travels on the row and in the method argument, the same
 * discipline core-service's {@code ExecutionEngine} follows.
 */
@Entity
@Table(name = "plugin_installations")
public class PluginInstallation {

    /**
     * Whether the platform will attempt delivery.
     *
     * <p>PARKED is set by the dispatcher, not the tenant: after enough
     * consecutive failures a channel stops being attempted so a revoked
     * webhook cannot be retried on every run forever. Only a successful test
     * clears it — see {@code InstallationService#test}.
     */
    public enum Status { ACTIVE, PARKED }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    /** Matches a {@code PluginDescriptor#key()} — "slack", "github", … */
    @Column(name = "plugin_key", nullable = false, length = 64)
    private String pluginKey;

    @Column(name = "display_name", nullable = false, length = 128)
    private String displayName;

    /**
     * The whole config map as AES-256-GCM ciphertext. Encrypted wholesale
     * rather than per-field: a webhook URL is as much a credential as a
     * password, and splitting "secret" from "not secret" at rest would invite
     * getting that judgement wrong later.
     */
    @Column(name = "config_enc", nullable = false, columnDefinition = "TEXT")
    private String configEnc;

    /** The tenant's own on/off switch, independent of {@link Status}. */
    @Column(nullable = false)
    private boolean enabled = true;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition = "ENUM('ACTIVE','PARKED')")
    private Status status = Status.ACTIVE;

    @Column(name = "last_test_ok")
    private Boolean lastTestOk;

    @Column(name = "last_test_at")
    private Instant lastTestAt;

    @Column(name = "last_test_detail", length = 1024)
    private String lastTestDetail;

    /** Reset to zero by any success; drives the park decision. */
    @Column(name = "consecutive_failures", nullable = false)
    private int consecutiveFailures;

    @Column(name = "created_by", length = 255)
    private String createdBy;

    @Column(name = "created_at", insertable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", insertable = false, updatable = false)
    private Instant updatedAt;

    public PluginInstallation() {
    }

    /** True only when the tenant wants it on AND the platform has not parked it. */
    public boolean isDeliverable() {
        return enabled && status == Status.ACTIVE;
    }

    public void recordSuccess() {
        this.consecutiveFailures = 0;
        if (this.status == Status.PARKED) {
            this.status = Status.ACTIVE;
        }
    }

    /**
     * Counts a failure and parks the channel once it has failed this many
     * times with nothing in between.
     *
     * <p>Only permanent failures should reach here with {@code retryable}
     * false; a timeout must not park a channel that is merely slow.
     */
    public void recordFailure(int maxConsecutiveFailures) {
        this.consecutiveFailures++;
        if (this.consecutiveFailures >= maxConsecutiveFailures) {
            this.status = Status.PARKED;
        }
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

    public String getPluginKey() {
        return pluginKey;
    }

    public void setPluginKey(String pluginKey) {
        this.pluginKey = pluginKey;
    }

    public String getDisplayName() {
        return displayName;
    }

    public void setDisplayName(String displayName) {
        this.displayName = displayName;
    }

    public String getConfigEnc() {
        return configEnc;
    }

    public void setConfigEnc(String configEnc) {
        this.configEnc = configEnc;
    }

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public Status getStatus() {
        return status;
    }

    public void setStatus(Status status) {
        this.status = status;
    }

    public Boolean getLastTestOk() {
        return lastTestOk;
    }

    public void setLastTestOk(Boolean lastTestOk) {
        this.lastTestOk = lastTestOk;
    }

    public Instant getLastTestAt() {
        return lastTestAt;
    }

    public void setLastTestAt(Instant lastTestAt) {
        this.lastTestAt = lastTestAt;
    }

    public String getLastTestDetail() {
        return lastTestDetail;
    }

    public void setLastTestDetail(String lastTestDetail) {
        this.lastTestDetail = lastTestDetail;
    }

    public int getConsecutiveFailures() {
        return consecutiveFailures;
    }

    public void setConsecutiveFailures(int consecutiveFailures) {
        this.consecutiveFailures = consecutiveFailures;
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
