package com.intertec.autoops.subscription.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

@Entity
@Table(name = "subscription_audit_log")
public class SubscriptionAuditLog {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Enumerated(EnumType.STRING)
    @Column(name = "event_type", nullable = false, columnDefinition =
            "ENUM('SUBSCRIBED','PLAN_CHANGED','REACTIVATED','CANCELED',"
            + "'PAYMENT_SUCCEEDED','PAYMENT_FAILED','PLAN_UPDATED')")
    private SubscriptionEventType eventType;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Enumerated(EnumType.STRING)
    @Column(name = "plan_code", columnDefinition =
            "ENUM('STARTER','TEAM','BUSINESS','ENTERPRISE')")
    private PlanCode planCode;

    /** JWT subject (email) of the admin acting. */
    @Column(length = 255)
    private String actor;

    /** Free text; must never contain tokens. */
    @Column(length = 1024)
    private String detail;

    @Column(name = "created_at", insertable = false, updatable = false)
    private Instant createdAt;

    public SubscriptionAuditLog() {
    }

    public Long getId() {
        return id;
    }

    public SubscriptionEventType getEventType() {
        return eventType;
    }

    public void setEventType(SubscriptionEventType eventType) {
        this.eventType = eventType;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public PlanCode getPlanCode() {
        return planCode;
    }

    public void setPlanCode(PlanCode planCode) {
        this.planCode = planCode;
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
