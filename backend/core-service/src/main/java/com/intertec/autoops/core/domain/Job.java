package com.intertec.autoops.core.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;

import java.time.Instant;
import java.time.LocalDateTime;

/**
 * A job definition: an ordered pipeline of steps stored as JSON, whose
 * {@code steps} array size is counted SERVER-SIDE (never client-supplied).
 * Creation is gated by the plan's MAX_JOBS. Execution is a later engine.
 */
@Entity
@Table(name = "jobs")
public class Job {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "project_id", nullable = false)
    private Project project;

    @Column(nullable = false, length = 128)
    private String name;

    /** Folder-style grouping, e.g. "database/cleanup". */
    @Column(name = "job_group", length = 64)
    private String jobGroup;

    @Column(length = 255)
    private String description;

    /** Steps JSON: {@code {"steps":[{type,label,category},...]}}. */
    @Column(columnDefinition = "MEDIUMTEXT")
    private String definition;

    @Column(name = "step_count", nullable = false)
    private int stepCount;

    /** Cron expression (5-field unix or 6-field Spring), validated on save. */
    @Column(length = 64)
    private String schedule;

    /**
     * IANA zone the cron is evaluated in, e.g. {@code America/Chicago}. Never
     * null — a job without an explicit zone is UTC, which is how every job
     * behaved before schedules became zone-aware.
     */
    @Column(name = "schedule_timezone", nullable = false, length = 64)
    private String scheduleTimezone = "UTC";

    /**
     * Local wall-clock slot a scheduled run was last queued for, read in
     * {@link #scheduleTimezone}. Exists only to collapse the hour that repeats
     * on a DST fall-back day into a single run; null until the job first fires,
     * and cleared whenever the timezone changes (the reading would otherwise
     * refer to a different zone's clock).
     */
    @Column(name = "last_fired_local")
    private LocalDateTime lastFiredLocal;

    /**
     * Next scheduler fire time as an absolute instant; recomputed whenever
     * schedule/timezone/enabled changes. Always UTC regardless of the zone the
     * cron is written in.
     */
    @Column(name = "next_run_at")
    private Instant nextRunAt;

    /**
     * The {@link #nextRunAt} slot already reported as MISSED, so the watchdog
     * alerts once per overdue slot rather than on every sweep.
     *
     * <p>Compared for equality, not recency: once the scheduler recovers it
     * advances {@code nextRunAt} to a new slot, and that slot is eligible to
     * be missed on its own merits.
     */
    @Column(name = "missed_notified_for")
    private Instant missedNotifiedFor;

    @Column(nullable = false)
    private boolean enabled = true;

    /** Manual non-admin runs need an ADMIN sign-off (approvals table). */
    @Column(name = "requires_approval", nullable = false)
    private boolean requiresApproval = false;

    @Column(name = "created_by", length = 255)
    private String createdBy;

    @Column(name = "created_at", insertable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", insertable = false, updatable = false)
    private Instant updatedAt;

    public Job() {
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

    public Project getProject() {
        return project;
    }

    public void setProject(Project project) {
        this.project = project;
    }

    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    public String getJobGroup() {
        return jobGroup;
    }

    public void setJobGroup(String jobGroup) {
        this.jobGroup = jobGroup;
    }

    public String getDescription() {
        return description;
    }

    public void setDescription(String description) {
        this.description = description;
    }

    public String getDefinition() {
        return definition;
    }

    public void setDefinition(String definition) {
        this.definition = definition;
    }

    public int getStepCount() {
        return stepCount;
    }

    public void setStepCount(int stepCount) {
        this.stepCount = stepCount;
    }

    public String getSchedule() {
        return schedule;
    }

    public void setSchedule(String schedule) {
        this.schedule = schedule;
    }

    public String getScheduleTimezone() {
        return scheduleTimezone;
    }

    public void setScheduleTimezone(String scheduleTimezone) {
        this.scheduleTimezone = scheduleTimezone;
    }

    public LocalDateTime getLastFiredLocal() {
        return lastFiredLocal;
    }

    public void setLastFiredLocal(LocalDateTime lastFiredLocal) {
        this.lastFiredLocal = lastFiredLocal;
    }

    public Instant getNextRunAt() {
        return nextRunAt;
    }

    public void setNextRunAt(Instant nextRunAt) {
        this.nextRunAt = nextRunAt;
    }

    public Instant getMissedNotifiedFor() {
        return missedNotifiedFor;
    }

    public void setMissedNotifiedFor(Instant missedNotifiedFor) {
        this.missedNotifiedFor = missedNotifiedFor;
    }

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public boolean isRequiresApproval() {
        return requiresApproval;
    }

    public void setRequiresApproval(boolean requiresApproval) {
        this.requiresApproval = requiresApproval;
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

    public Instant getUpdatedAt() {
        return updatedAt;
    }
}
