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
 * One tenant-wide notification (run failed, approval requested, ...). Read
 * state is per member and lives in {@code notification_reads}, managed by the
 * service — a notification row itself is immutable.
 */
@Entity
@Table(name = "notifications")
public class AppNotification {

    public enum Kind { SYSTEM, ALERT, PROVIDER }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition = "ENUM('SYSTEM','ALERT','PROVIDER')")
    private Kind kind = Kind.SYSTEM;

    @Column(nullable = false, length = 255)
    private String title;

    @Column(length = 1024)
    private String body;

    @Column(length = 255)
    private String link;

    /** Set in code (like Run.createdAt) so H2 tests get a value too. */
    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt = Instant.now();

    public Long getId() {
        return id;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public Kind getKind() {
        return kind;
    }

    public void setKind(Kind kind) {
        this.kind = kind;
    }

    public String getTitle() {
        return title;
    }

    public void setTitle(String title) {
        this.title = title;
    }

    public String getBody() {
        return body;
    }

    public void setBody(String body) {
        this.body = body;
    }

    public String getLink() {
        return link;
    }

    public void setLink(String link) {
        this.link = link;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }
}
