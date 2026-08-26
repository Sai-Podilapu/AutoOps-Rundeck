package com.intertec.autoops.rundeck.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

/**
 * An AutoOps job's counterpart on the platform engine.
 *
 * <p>Records identity and sync state only — never the job's steps. The
 * definition belongs to core-service, and a second copy here would go stale the
 * moment someone edits the job.
 */
@Entity
@Table(name = "rundeck_jobs")
public class RundeckJob {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Column(name = "project_id", nullable = false)
    private Long projectId;

    @Column(name = "autoops_job_id", nullable = false)
    private Long autoopsJobId;

    @Column(name = "rundeck_project", nullable = false, length = 255)
    private String rundeckProject;

    /**
     * Derived from (tenant, autoopsJobId) rather than assigned by Rundeck, so a
     * re-import updates the same job instead of creating a duplicate.
     */
    @Column(name = "rundeck_job_uuid", nullable = false, length = 36)
    private String rundeckJobUuid;

    /** False when the last import failed; the job exists in AutoOps regardless. */
    @Column(name = "imported", nullable = false)
    private boolean imported;

    @Column(name = "last_error", length = 512)
    private String lastError;

    /**
     * Whether the ENGINE fires this job's schedule.
     *
     * <p>The flag that prevents double execution. While core-service's
     * {@code JobScheduler} still fires the job, this stays false and the
     * imported definition carries {@code scheduleEnabled: false} — otherwise
     * both schedulers hold the same cron and every run happens twice.
     */
    @Column(name = "schedule_owned_by_engine", nullable = false)
    private boolean scheduleOwnedByEngine;

    @Column(name = "created_at", nullable = false)
    private Instant createdAt = Instant.now();

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt = Instant.now();

    public Long getId() {
        return id;
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

    public Long getAutoopsJobId() {
        return autoopsJobId;
    }

    public void setAutoopsJobId(Long autoopsJobId) {
        this.autoopsJobId = autoopsJobId;
    }

    public String getRundeckProject() {
        return rundeckProject;
    }

    public void setRundeckProject(String rundeckProject) {
        this.rundeckProject = rundeckProject;
    }

    public String getRundeckJobUuid() {
        return rundeckJobUuid;
    }

    public void setRundeckJobUuid(String rundeckJobUuid) {
        this.rundeckJobUuid = rundeckJobUuid;
    }

    public boolean isImported() {
        return imported;
    }

    public void setImported(boolean imported) {
        this.imported = imported;
    }

    public String getLastError() {
        return lastError;
    }

    public void setLastError(String lastError) {
        this.lastError = lastError;
    }

    public boolean isScheduleOwnedByEngine() {
        return scheduleOwnedByEngine;
    }

    public void setScheduleOwnedByEngine(boolean scheduleOwnedByEngine) {
        this.scheduleOwnedByEngine = scheduleOwnedByEngine;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    public Instant getUpdatedAt() {
        return updatedAt;
    }

    public void setUpdatedAt(Instant updatedAt) {
        this.updatedAt = updatedAt;
    }
}
