package com.intertec.autoops.agent.domain;

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
 * One execution of an agent: the question, the conversation it produced, and
 * the answer.
 *
 * <p>The row exists because an agent run is not a request/response. It calls a
 * model, the model asks for a tool, the tool takes minutes, the model is asked
 * again — and somewhere in the middle it may stop for a human and not move
 * again until tomorrow. None of that survives in memory, so all of it lives
 * here.
 *
 * <p>{@code model} and {@code vendor} are COPIES, not lookups. An agent's model
 * can be changed after this run finished, and the record has to keep saying
 * which model actually produced this answer.
 */
@Entity
@Table(name = "agent_runs")
public class AgentRun {

    /**
     * PENDING → RUNNING → SUCCEEDED | FAILED | CANCELLED, with
     * AWAITING_APPROVAL as the one state that can be left and re-entered.
     */
    public enum Status {
        PENDING, RUNNING, AWAITING_APPROVAL, SUCCEEDED, FAILED, CANCELLED;

        public boolean isTerminal() {
            return this == SUCCEEDED || this == FAILED || this == CANCELLED;
        }
    }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Column(name = "agent_id", nullable = false)
    private Long agentId;

    @Column(name = "project_id", nullable = false)
    private Long projectId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition = "ENUM('PENDING','RUNNING','AWAITING_APPROVAL',"
            + "'SUCCEEDED','FAILED','CANCELLED')")
    private Status status = Status.PENDING;

    @Column(nullable = false, columnDefinition = "MEDIUMTEXT")
    private String input;

    @Column(columnDefinition = "MEDIUMTEXT")
    private String output;

    /** The provider-neutral message history as JSON — see the V4 migration. */
    @Column(columnDefinition = "MEDIUMTEXT")
    private String transcript;

    @Column(length = 128)
    private String model;

    @Column(length = 32)
    private String vendor;

    @Column(name = "step_count", nullable = false)
    private int stepCount;

    @Column(name = "max_steps", nullable = false)
    private int maxSteps = 12;

    /** core-service approval id, set only while AWAITING_APPROVAL. */
    @Column(name = "approval_reference", length = 64)
    private String approvalReference;

    /** The tool_use id the approval belongs to; the result must carry it back. */
    @Column(name = "pending_tool_id", length = 128)
    private String pendingToolId;

    @Column(columnDefinition = "TEXT")
    private String error;

    @Column(name = "prompt_tokens", nullable = false)
    private long promptTokens;

    @Column(name = "completion_tokens", nullable = false)
    private long completionTokens;

    @Column(name = "created_by", length = 255)
    private String createdBy;

    @Column(name = "created_at", insertable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "started_at")
    private Instant startedAt;

    @Column(name = "finished_at")
    private Instant finishedAt;

    public AgentRun() {
    }

    public Long getId() {
        return id;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public Long getAgentId() {
        return agentId;
    }

    public void setAgentId(Long agentId) {
        this.agentId = agentId;
    }

    public Long getProjectId() {
        return projectId;
    }

    public void setProjectId(Long projectId) {
        this.projectId = projectId;
    }

    public Status getStatus() {
        return status;
    }

    public void setStatus(Status status) {
        this.status = status;
    }

    public String getInput() {
        return input;
    }

    public void setInput(String input) {
        this.input = input;
    }

    public String getOutput() {
        return output;
    }

    public void setOutput(String output) {
        this.output = output;
    }

    public String getTranscript() {
        return transcript;
    }

    public void setTranscript(String transcript) {
        this.transcript = transcript;
    }

    public String getModel() {
        return model;
    }

    public void setModel(String model) {
        this.model = model;
    }

    public String getVendor() {
        return vendor;
    }

    public void setVendor(String vendor) {
        this.vendor = vendor;
    }

    public int getStepCount() {
        return stepCount;
    }

    public void setStepCount(int stepCount) {
        this.stepCount = stepCount;
    }

    public int getMaxSteps() {
        return maxSteps;
    }

    public void setMaxSteps(int maxSteps) {
        this.maxSteps = maxSteps;
    }

    public String getApprovalReference() {
        return approvalReference;
    }

    public void setApprovalReference(String approvalReference) {
        this.approvalReference = approvalReference;
    }

    public String getPendingToolId() {
        return pendingToolId;
    }

    public void setPendingToolId(String pendingToolId) {
        this.pendingToolId = pendingToolId;
    }

    public String getError() {
        return error;
    }

    public void setError(String error) {
        this.error = error;
    }

    public long getPromptTokens() {
        return promptTokens;
    }

    public void setPromptTokens(long promptTokens) {
        this.promptTokens = promptTokens;
    }

    public long getCompletionTokens() {
        return completionTokens;
    }

    public void setCompletionTokens(long completionTokens) {
        this.completionTokens = completionTokens;
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

    public Instant getStartedAt() {
        return startedAt;
    }

    public void setStartedAt(Instant startedAt) {
        this.startedAt = startedAt;
    }

    public Instant getFinishedAt() {
        return finishedAt;
    }

    public void setFinishedAt(Instant finishedAt) {
        this.finishedAt = finishedAt;
    }
}
