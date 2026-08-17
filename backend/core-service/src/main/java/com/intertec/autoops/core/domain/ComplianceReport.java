package com.intertec.autoops.core.domain;

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
 * A generated compliance report. The findings JSON in {@code content} is a
 * snapshot taken at generation time — it never changes as the project does.
 */
@Entity
@Table(name = "compliance_reports")
public class ComplianceReport {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Column(name = "project_id", nullable = false)
    private Long projectId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition = "ENUM('SOC2','ISO_27001','HIPAA','PCI_DSS','GDPR')")
    private ComplianceFramework framework;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition = "ENUM('COMPLIANT','NON_COMPLIANT')")
    private ComplianceStatus status;

    @Column(nullable = false)
    private int score;

    @Column(name = "controls_total", nullable = false)
    private int controlsTotal;

    @Column(nullable = false)
    private int passed;

    @Column(nullable = false)
    private int warnings;

    @Column(nullable = false)
    private int failed;

    @Column(nullable = false, columnDefinition = "MEDIUMTEXT")
    private String content;

    @Column(name = "generated_by", length = 255)
    private String generatedBy;

    @Column(name = "created_at", updatable = false)
    private Instant createdAt = Instant.now();

    public ComplianceReport() {
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

    public Long getProjectId() {
        return projectId;
    }

    public void setProjectId(Long projectId) {
        this.projectId = projectId;
    }

    public ComplianceFramework getFramework() {
        return framework;
    }

    public void setFramework(ComplianceFramework framework) {
        this.framework = framework;
    }

    public ComplianceStatus getStatus() {
        return status;
    }

    public void setStatus(ComplianceStatus status) {
        this.status = status;
    }

    public int getScore() {
        return score;
    }

    public void setScore(int score) {
        this.score = score;
    }

    public int getControlsTotal() {
        return controlsTotal;
    }

    public void setControlsTotal(int controlsTotal) {
        this.controlsTotal = controlsTotal;
    }

    public int getPassed() {
        return passed;
    }

    public void setPassed(int passed) {
        this.passed = passed;
    }

    public int getWarnings() {
        return warnings;
    }

    public void setWarnings(int warnings) {
        this.warnings = warnings;
    }

    public int getFailed() {
        return failed;
    }

    public void setFailed(int failed) {
        this.failed = failed;
    }

    public String getContent() {
        return content;
    }

    public void setContent(String content) {
        this.content = content;
    }

    public String getGeneratedBy() {
        return generatedBy;
    }

    public void setGeneratedBy(String generatedBy) {
        this.generatedBy = generatedBy;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }
}