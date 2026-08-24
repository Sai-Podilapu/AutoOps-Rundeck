package com.intertec.autoops.rundeck.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

/**
 * The AutoOps-side receipt for a job WE told Rundeck to run.
 *
 * <p>Rundeck keeps the execution and its log; this keeps the fact that AutoOps
 * asked, who asked, and with what. Without it, a dispatch becomes unattributable
 * the moment the connection is deleted or the API token is rotated — and "who
 * ran this on production" is exactly the question that gets asked afterwards.
 *
 * <p>{@code status} is a snapshot from the last poll, never the authority. The
 * execution view always re-reads Rundeck for the live answer.
 */
@Entity
@Table(name = "rundeck_dispatches")
public class RundeckDispatch {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    /** The AutoOps run this step belonged to — what an auditor actually asks about. */
    @Column(name = "run_id")
    private Long runId;

    @Column(name = "step_index")
    private Integer stepIndex;

    @Column(name = "step_type", length = 32)
    private String stepType;

    @Column(name = "rundeck_project", length = 255)
    private String rundeckProject;

    /**
     * Null for ad-hoc step execution, which is now the only path. Kept because
     * a saved Rundeck job may be dispatched later, and a nullable column beats
     * a placeholder that looks like an id.
     */
    @Column(name = "job_id", length = 64)
    private String jobId;

    /** Snapshotted: a Rundeck job can be renamed after we ran it. */
    @Column(name = "job_name", length = 255)
    private String jobName;

    @Column(name = "execution_id")
    private Long executionId;

    @Column(name = "node_filter", length = 512)
    private String nodeFilter;

    /** Submitted option values, with anything Rundeck marks secure removed. */
    @Column(name = "options_json", columnDefinition = "TEXT")
    private String optionsJson;

    @Column(nullable = false, length = 32)
    private String status = "SUBMITTED";

    @Column(name = "triggered_by", length = 255)
    private String triggeredBy;

    @Column(length = 512)
    private String error;

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

    public Long getRunId() {
        return runId;
    }

    public void setRunId(Long runId) {
        this.runId = runId;
    }

    public Integer getStepIndex() {
        return stepIndex;
    }

    public void setStepIndex(Integer stepIndex) {
        this.stepIndex = stepIndex;
    }

    public String getStepType() {
        return stepType;
    }

    public void setStepType(String stepType) {
        this.stepType = stepType;
    }

    public String getRundeckProject() {
        return rundeckProject;
    }

    public void setRundeckProject(String rundeckProject) {
        this.rundeckProject = rundeckProject;
    }

    public String getJobId() {
        return jobId;
    }

    public void setJobId(String jobId) {
        this.jobId = jobId;
    }

    public String getJobName() {
        return jobName;
    }

    public void setJobName(String jobName) {
        this.jobName = jobName;
    }

    public Long getExecutionId() {
        return executionId;
    }

    public void setExecutionId(Long executionId) {
        this.executionId = executionId;
    }

    public String getNodeFilter() {
        return nodeFilter;
    }

    public void setNodeFilter(String nodeFilter) {
        this.nodeFilter = nodeFilter;
    }

    public String getOptionsJson() {
        return optionsJson;
    }

    public void setOptionsJson(String optionsJson) {
        this.optionsJson = optionsJson;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public String getTriggeredBy() {
        return triggeredBy;
    }

    public void setTriggeredBy(String triggeredBy) {
        this.triggeredBy = triggeredBy;
    }

    public String getError() {
        return error;
    }

    public void setError(String error) {
        this.error = error;
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
