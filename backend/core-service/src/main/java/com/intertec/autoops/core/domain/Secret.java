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
 * One vault entry. The value is AES-GCM ciphertext and is WRITE-ONLY through
 * the API — no endpoint ever returns it. Path is unique per tenant.
 */
@Entity
@Table(name = "secrets")
public class Secret {

    public enum Type { OPAQUE, TLS, SSH }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Column(nullable = false, length = 255)
    private String path;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition = "ENUM('OPAQUE','TLS','SSH')")
    private Type type = Type.OPAQUE;

    @Column(name = "value_enc", nullable = false, columnDefinition = "TEXT")
    private String valueEnc;

    @Column(name = "created_by", length = 255)
    private String createdBy;

    /** Set in code (H2 tests have no DB default). */
    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt = Instant.now();

    @Column(name = "updated_at", insertable = false, updatable = false)
    private Instant updatedAt;

    public Long getId() {
        return id;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public String getPath() {
        return path;
    }

    public void setPath(String path) {
        this.path = path;
    }

    public Type getType() {
        return type;
    }

    public void setType(Type type) {
        this.type = type;
    }

    public String getValueEnc() {
        return valueEnc;
    }

    public void setValueEnc(String valueEnc) {
        this.valueEnc = valueEnc;
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
