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
 * One event inside a run, in the order it happened.
 *
 * <p>This is the audit trail, and it is written for a person who has to answer
 * "why did that server reboot" after the fact. So a failed tool gets a row like
 * any other — a failure is a thing that HAPPENED, not a thing that is missing —
 * and {@code isError} is how a reader tells the two apart.
 */
@Entity
@Table(name = "agent_run_steps")
public class AgentRunStep {

    public enum Kind {
        MODEL_CALL, TOOL_CALL, TOOL_RESULT, APPROVAL_REQUESTED, APPROVAL_GRANTED
    }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "run_id", nullable = false)
    private Long runId;

    /** Monotonic within a run; ordering by id would break on any backfill. */
    @Column(nullable = false)
    private int seq;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition = "ENUM('MODEL_CALL','TOOL_CALL','TOOL_RESULT',"
            + "'APPROVAL_REQUESTED','APPROVAL_GRANTED')")
    private Kind kind;

    @Column(name = "tool_type", length = 16)
    private String toolType;

    @Column(name = "tool_target_id")
    private Long toolTargetId;

    @Column(name = "tool_name", length = 255)
    private String toolName;

    @Column(columnDefinition = "MEDIUMTEXT")
    private String request;

    @Column(columnDefinition = "MEDIUMTEXT")
    private String response;

    @Column(name = "is_error", nullable = false)
    private boolean error;

    @Column(name = "duration_ms")
    private Long durationMs;

    @Column(name = "created_at", insertable = false, updatable = false)
    private Instant createdAt;

    public AgentRunStep() {
    }

    public Long getId() {
        return id;
    }

    public Long getRunId() {
        return runId;
    }

    public void setRunId(Long runId) {
        this.runId = runId;
    }

    public int getSeq() {
        return seq;
    }

    public void setSeq(int seq) {
        this.seq = seq;
    }

    public Kind getKind() {
        return kind;
    }

    public void setKind(Kind kind) {
        this.kind = kind;
    }

    public String getToolType() {
        return toolType;
    }

    public void setToolType(String toolType) {
        this.toolType = toolType;
    }

    public Long getToolTargetId() {
        return toolTargetId;
    }

    public void setToolTargetId(Long toolTargetId) {
        this.toolTargetId = toolTargetId;
    }

    public String getToolName() {
        return toolName;
    }

    public void setToolName(String toolName) {
        this.toolName = toolName;
    }

    public String getRequest() {
        return request;
    }

    public void setRequest(String request) {
        this.request = request;
    }

    public String getResponse() {
        return response;
    }

    public void setResponse(String response) {
        this.response = response;
    }

    public boolean isError() {
        return error;
    }

    public void setError(boolean error) {
        this.error = error;
    }

    public Long getDurationMs() {
        return durationMs;
    }

    public void setDurationMs(Long durationMs) {
        this.durationMs = durationMs;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }
}
