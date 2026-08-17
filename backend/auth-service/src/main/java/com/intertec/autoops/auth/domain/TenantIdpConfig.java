package com.intertec.autoops.auth.domain;

import jakarta.persistence.CollectionTable;
import jakarta.persistence.Column;
import jakarta.persistence.ElementCollection;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.Table;

import java.time.Instant;
import java.util.LinkedHashSet;
import java.util.Set;

/**
 * A tenant's OWN OIDC identity provider (the Enterprise "SSO" feature). The
 * client_id/secret belong to an app the TENANT registered in THEIR IdP;
 * email domains drive login-page routing and are globally unique.
 */
@Entity
@Table(name = "tenant_idp_config")
public class TenantIdpConfig {

    @Id
    @Column(name = "tenant_id", length = 64)
    private String tenantId;

    @Column(nullable = false, length = 255)
    private String issuer;

    @Column(name = "authorize_url", nullable = false, length = 255)
    private String authorizeUrl;

    @Column(name = "token_url", nullable = false, length = 255)
    private String tokenUrl;

    @Column(name = "userinfo_url", nullable = false, length = 255)
    private String userinfoUrl;

    @Column(name = "client_id", nullable = false, length = 255)
    private String clientId;

    @Column(name = "client_secret", nullable = false, length = 255)
    private String clientSecret;

    /** Blocks password/OTP login for MEMBERS (admins keep break-glass access). */
    @Column(name = "enforce_sso", nullable = false)
    private boolean enforceSso;

    @Column(nullable = false)
    private boolean enabled = true;

    @ElementCollection(fetch = FetchType.EAGER)
    @CollectionTable(name = "tenant_idp_domains", joinColumns = @JoinColumn(name = "tenant_id"))
    @Column(name = "domain", nullable = false, length = 128)
    private Set<String> emailDomains = new LinkedHashSet<>();

    @Column(name = "created_at", insertable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", insertable = false, updatable = false)
    private Instant updatedAt;

    public TenantIdpConfig() {
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public String getIssuer() {
        return issuer;
    }

    public void setIssuer(String issuer) {
        this.issuer = issuer;
    }

    public String getAuthorizeUrl() {
        return authorizeUrl;
    }

    public void setAuthorizeUrl(String authorizeUrl) {
        this.authorizeUrl = authorizeUrl;
    }

    public String getTokenUrl() {
        return tokenUrl;
    }

    public void setTokenUrl(String tokenUrl) {
        this.tokenUrl = tokenUrl;
    }

    public String getUserinfoUrl() {
        return userinfoUrl;
    }

    public void setUserinfoUrl(String userinfoUrl) {
        this.userinfoUrl = userinfoUrl;
    }

    public String getClientId() {
        return clientId;
    }

    public void setClientId(String clientId) {
        this.clientId = clientId;
    }

    public String getClientSecret() {
        return clientSecret;
    }

    public void setClientSecret(String clientSecret) {
        this.clientSecret = clientSecret;
    }

    public boolean isEnforceSso() {
        return enforceSso;
    }

    public void setEnforceSso(boolean enforceSso) {
        this.enforceSso = enforceSso;
    }

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public Set<String> getEmailDomains() {
        return emailDomains;
    }

    public void setEmailDomains(Set<String> emailDomains) {
        this.emailDomains = emailDomains;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    public Instant getUpdatedAt() {
        return updatedAt;
    }
}
