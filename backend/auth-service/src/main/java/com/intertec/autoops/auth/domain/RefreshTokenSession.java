package com.intertec.autoops.auth.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

@Entity
@Table(name = "refresh_token_sessions")
public class RefreshTokenSession {

    /** UUID — the public half of the refresh token ({sessionId}.{secret}). */
    @Id
    @Column(name = "session_id", columnDefinition = "CHAR(36)")
    private String sessionId;

    @Column(name = "user_id", nullable = false)
    private Long userId;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    /** SHA-256 hex of the 48-byte secret half. The secret itself is never stored. */
    @Column(name = "token_hash", nullable = false, columnDefinition = "CHAR(64)")
    private String tokenHash;

    @Column(name = "device_id", length = 128)
    private String deviceId;

    /** IPv4/IPv6, resolved via the XFF chain. */
    @Column(name = "ip_address", length = 45)
    private String ipAddress;

    @Column(name = "user_agent", length = 512)
    private String userAgent;

    @Column(name = "issued_at", nullable = false)
    private Instant issuedAt;

    @Column(name = "expires_at", nullable = false)
    private Instant expiresAt;

    @Column(name = "revoked_at")
    private Instant revokedAt;

    /** Rotation chain link. */
    @Column(name = "replaced_by_session", columnDefinition = "CHAR(36)")
    private String replacedBySession;

    /** true => a rotated token was replayed and the family was revoked. */
    @Column(name = "reuse_detected", nullable = false)
    private boolean reuseDetected;

    public RefreshTokenSession() {
    }

    public String getSessionId() {
        return sessionId;
    }

    public void setSessionId(String sessionId) {
        this.sessionId = sessionId;
    }

    public Long getUserId() {
        return userId;
    }

    public void setUserId(Long userId) {
        this.userId = userId;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public String getTokenHash() {
        return tokenHash;
    }

    public void setTokenHash(String tokenHash) {
        this.tokenHash = tokenHash;
    }

    public String getDeviceId() {
        return deviceId;
    }

    public void setDeviceId(String deviceId) {
        this.deviceId = deviceId;
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

    public Instant getIssuedAt() {
        return issuedAt;
    }

    public void setIssuedAt(Instant issuedAt) {
        this.issuedAt = issuedAt;
    }

    public Instant getExpiresAt() {
        return expiresAt;
    }

    public void setExpiresAt(Instant expiresAt) {
        this.expiresAt = expiresAt;
    }

    public Instant getRevokedAt() {
        return revokedAt;
    }

    public void setRevokedAt(Instant revokedAt) {
        this.revokedAt = revokedAt;
    }

    public String getReplacedBySession() {
        return replacedBySession;
    }

    public void setReplacedBySession(String replacedBySession) {
        this.replacedBySession = replacedBySession;
    }

    public boolean isReuseDetected() {
        return reuseDetected;
    }

    public void setReuseDetected(boolean reuseDetected) {
        this.reuseDetected = reuseDetected;
    }
}
