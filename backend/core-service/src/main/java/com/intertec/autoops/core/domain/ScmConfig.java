package com.intertec.autoops.core.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

/** Per-project git sync target; token encrypted at rest (token_enc). */
@Entity
@Table(name = "scm_configs")
public class ScmConfig {

    @Id
    @Column(name = "project_id")
    private Long projectId;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Column(name = "repo_url", nullable = false, length = 512)
    private String repoUrl;

    @Column(nullable = false, length = 128)
    private String branch = "main";

    /** Directory inside the repo that holds the exported files ("" = root). */
    @Column(name = "base_path", nullable = false, length = 256)
    private String basePath = "";

    @Column(length = 128)
    private String username;

    @Column(name = "token_enc", columnDefinition = "TEXT")
    private String tokenEnc;

    @Column(name = "updated_by", length = 255)
    private String updatedBy;

    @Column(name = "updated_at", insertable = false, updatable = false)
    private Instant updatedAt;

    public ScmConfig() {
    }

    public Long getProjectId() {
        return projectId;
    }

    public void setProjectId(Long projectId) {
        this.projectId = projectId;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public String getRepoUrl() {
        return repoUrl;
    }

    public void setRepoUrl(String repoUrl) {
        this.repoUrl = repoUrl;
    }

    public String getBranch() {
        return branch;
    }

    public void setBranch(String branch) {
        this.branch = branch;
    }

    public String getBasePath() {
        return basePath;
    }

    public void setBasePath(String basePath) {
        this.basePath = basePath;
    }

    public String getUsername() {
        return username;
    }

    public void setUsername(String username) {
        this.username = username;
    }

    public String getTokenEnc() {
        return tokenEnc;
    }

    public void setTokenEnc(String tokenEnc) {
        this.tokenEnc = tokenEnc;
    }

    public String getUpdatedBy() {
        return updatedBy;
    }

    public void setUpdatedBy(String updatedBy) {
        this.updatedBy = updatedBy;
    }

    public Instant getUpdatedAt() {
        return updatedAt;
    }
}
