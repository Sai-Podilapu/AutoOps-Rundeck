package com.intertec.autoops.subscription.domain;

import jakarta.persistence.CollectionTable;
import jakarta.persistence.Column;
import jakarta.persistence.ElementCollection;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.FetchType;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.Table;

import java.time.Instant;
import java.util.EnumSet;
import java.util.Set;

@Entity
@Table(name = "plans")
public class Plan {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition = "ENUM('STARTER','TEAM','BUSINESS','ENTERPRISE')")
    private PlanCode code;

    @Column(nullable = false, length = 64)
    private String name;

    @Column(nullable = false)
    private String description;

    /** USD per month, whole dollars (stub billing — no cents/currency yet). */
    @Column(name = "price_monthly", nullable = false)
    private int priceMonthly;

    /** NULL = unlimited. */
    @Column(name = "max_projects")
    private Integer maxProjects;

    @Column(name = "max_nodes")
    private Integer maxNodes;

    @Column(name = "max_automations")
    private Integer maxAutomations;

    @Column(name = "max_jobs")
    private Integer maxJobs;

    @Column(name = "max_cloud_integrations")
    private Integer maxCloudIntegrations;

    @Column(name = "history_days")
    private Integer historyDays;

    @Column(name = "trial_days", nullable = false)
    private int trialDays = 14;

    @Column(nullable = false)
    private boolean active = true;

    @Column(name = "sort_order", nullable = false)
    private int sortOrder;

    @ElementCollection(fetch = FetchType.EAGER)
    @CollectionTable(name = "plan_features", joinColumns = @JoinColumn(name = "plan_id"))
    @Enumerated(EnumType.STRING)
    @Column(name = "feature", nullable = false, columnDefinition =
            "ENUM('CORE_AUTOMATION','PREMIUM_TEMPLATES','PRIVATE_TEMPLATES',"
            + "'SSO','ADVANCED_RBAC','AUDIT_LOG','API_ACCESS','COMPLIANCE_REPORTS',"
            + "'GOVERNANCE')")
    private Set<Feature> features = EnumSet.noneOf(Feature.class);

    @Column(name = "created_at", insertable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", insertable = false, updatable = false)
    private Instant updatedAt;

    public Plan() {
    }

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public PlanCode getCode() {
        return code;
    }

    public void setCode(PlanCode code) {
        this.code = code;
    }

    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    public String getDescription() {
        return description;
    }

    public void setDescription(String description) {
        this.description = description;
    }

    public int getPriceMonthly() {
        return priceMonthly;
    }

    public void setPriceMonthly(int priceMonthly) {
        this.priceMonthly = priceMonthly;
    }

    public Integer getMaxProjects() {
        return maxProjects;
    }

    public void setMaxProjects(Integer maxProjects) {
        this.maxProjects = maxProjects;
    }

    public Integer getMaxNodes() {
        return maxNodes;
    }

    public void setMaxNodes(Integer maxNodes) {
        this.maxNodes = maxNodes;
    }

    public Integer getMaxAutomations() {
        return maxAutomations;
    }

    public void setMaxAutomations(Integer maxAutomations) {
        this.maxAutomations = maxAutomations;
    }

    public Integer getMaxJobs() {
        return maxJobs;
    }

    public void setMaxJobs(Integer maxJobs) {
        this.maxJobs = maxJobs;
    }

    public Integer getMaxCloudIntegrations() {
        return maxCloudIntegrations;
    }

    public void setMaxCloudIntegrations(Integer maxCloudIntegrations) {
        this.maxCloudIntegrations = maxCloudIntegrations;
    }

    public Integer getHistoryDays() {
        return historyDays;
    }

    public void setHistoryDays(Integer historyDays) {
        this.historyDays = historyDays;
    }

    public int getTrialDays() {
        return trialDays;
    }

    public void setTrialDays(int trialDays) {
        this.trialDays = trialDays;
    }

    public boolean isActive() {
        return active;
    }

    public void setActive(boolean active) {
        this.active = active;
    }

    public int getSortOrder() {
        return sortOrder;
    }

    public void setSortOrder(int sortOrder) {
        this.sortOrder = sortOrder;
    }

    public Set<Feature> getFeatures() {
        return features;
    }

    public void setFeatures(Set<Feature> features) {
        this.features = features;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    public Instant getUpdatedAt() {
        return updatedAt;
    }
}
