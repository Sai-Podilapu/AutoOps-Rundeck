package com.intertec.autoops.auth.domain;

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
@Table(name = "auth_audit_log")
public class AuthAuditLog {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Enumerated(EnumType.STRING)
    @Column(name = "event_type", nullable = false, columnDefinition =
            "ENUM('OTP_REQUESTED','OTP_SENT','OTP_DELIVERY_FAILED',"
            + "'LOGIN_SUCCESS','LOGIN_FAILURE','OTP_LOCKOUT',"
            + "'TOKEN_REFRESH','REFRESH_REUSE',"
            + "'LOGOUT','LOGOUT_ALL','SSO_LOGIN',"
            + "'USER_ONBOARDED','USER_OFFBOARDED','RATE_LIMITED',"
            + "'EMAIL_VERIFIED','PASSWORD_RESET','PASSWORD_CHANGED',"
            + "'WORKSPACE_RENAMED','ROLE_CHANGED','IDP_CONFIGURED',"
            + "'PROFILE_UPDATED','API_KEY_CREATED','API_KEY_REVOKED')")
    private AuditEventType eventType;

    @Column(name = "user_id")
    private Long userId;

    @Column
    private String email;

    @Column(name = "tenant_id", length = 64)
    private String tenantId;

    @Column(name = "session_id", columnDefinition = "CHAR(36)")
    private String sessionId;

    @Column(name = "ip_address", length = 45)
    private String ipAddress;

    @Column(name = "user_agent", length = 512)
    private String userAgent;

    /** JSON or free text; must never contain secrets. */
    @Column(length = 1024)
    private String detail;

    @Column(name = "created_at", insertable = false, updatable = false)
    private Instant createdAt;

    public AuthAuditLog() {
    }

    public Long getId() {
        return id;
    }

    public AuditEventType getEventType() {
        return eventType;
    }

    public void setEventType(AuditEventType eventType) {
        this.eventType = eventType;
    }

    public Long getUserId() {
        return userId;
    }

    public void setUserId(Long userId) {
        this.userId = userId;
    }

    public String getEmail() {
        return email;
    }

    public void setEmail(String email) {
        this.email = email;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public String getSessionId() {
        return sessionId;
    }

    public void setSessionId(String sessionId) {
        this.sessionId = sessionId;
    }

    public String getIpAddress() {
        return ipAddress;
    }

    public void setIpAddress(String ipAddress) {
        this.ipAddress = ipAddress;
    }

    public String getUserAgent() {
        return userAgent;
    }

    public void setUserAgent(String userAgent) {
        this.userAgent = userAgent;
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
