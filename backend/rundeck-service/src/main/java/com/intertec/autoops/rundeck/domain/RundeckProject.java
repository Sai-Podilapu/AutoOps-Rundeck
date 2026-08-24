package com.intertec.autoops.rundeck.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

/**
 * The mapping that keeps tenants apart on one shared Rundeck.
 *
 * <p>With a Rundeck per customer, the API token was the boundary. With one
 * platform Rundeck behind every tenant, the boundary is a Rundeck <em>project</em>
 * — and this row is the only place an AutoOps (tenant, project) pair is bound
 * to a Rundeck project name.
 *
 * <p>The name is always computed, never supplied. Nothing in the codebase
 * accepts a Rundeck project name from a request; a caller who could type one
 * could address another workspace's fleet.
 */
@Entity
@Table(name = "rundeck_projects")
public class RundeckProject {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Column(name = "project_id", nullable = false)
    private Long projectId;

    @Column(name = "rundeck_project", nullable = false, length = 255)
    private String rundeckProject;

    /**
     * True once Rundeck confirmed the project exists. Provisioning is lazy and
     * idempotent, so the steady state is one indexed read per step rather than
     * an API call.
     */
    @Column(nullable = false)
    private boolean provisioned = false;

    @Column(name = "last_error", length = 512)
    private String lastError;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt = Instant.now();

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt = Instant.now();

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public Long getProjectId() {
        return projectId;
    }

    public void setProjectId(Long projectId) {
        this.projectId = projectId;
    }

    public String getRundeckProject() {
        return rundeckProject;
    }

    public void setRundeckProject(String rundeckProject) {
        this.rundeckProject = rundeckProject;
    }

    public boolean isProvisioned() {
        return provisioned;
    }

    public void setProvisioned(boolean provisioned) {
        this.provisioned = provisioned;
    }

    public String getLastError() {
        return lastError;
    }

    public void setLastError(String lastError) {
        this.lastError = lastError;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(Instant createdAt) {
        this.createdAt = createdAt;
    }

    public Instant getUpdatedAt() {
        return updatedAt;
    }

    public void setUpdatedAt(Instant updatedAt) {
        this.updatedAt = updatedAt;
    }
}
