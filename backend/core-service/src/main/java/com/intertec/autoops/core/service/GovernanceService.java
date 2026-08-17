package com.intertec.autoops.core.service;

import com.intertec.autoops.core.client.SubscriptionInfoClient;
import com.intertec.autoops.core.client.WorkflowClient;
import com.intertec.autoops.core.client.SubscriptionInfoClient.PlanLimits;
import com.intertec.autoops.core.domain.Approval;
import com.intertec.autoops.core.domain.ApprovalStatus;
import com.intertec.autoops.core.domain.CloudConnection;
import com.intertec.autoops.core.domain.ComplianceReport;
import com.intertec.autoops.core.domain.ConnectionStatus;
import com.intertec.autoops.core.domain.GovernancePolicy;
import com.intertec.autoops.core.domain.GovernancePolicyMode;
import com.intertec.autoops.core.domain.GovernancePolicySetting;
import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.domain.Project;
import com.intertec.autoops.core.domain.ProjectStatus;
import com.intertec.autoops.core.domain.RunStatus;
import com.intertec.autoops.core.domain.ScmConfig;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.ApprovalRepository;
import com.intertec.autoops.core.repo.CloudConnectionRepository;
import com.intertec.autoops.core.repo.ComplianceReportRepository;
import com.intertec.autoops.core.repo.GovernancePolicyRepository;
import com.intertec.autoops.core.repo.JobRepository;
import com.intertec.autoops.core.repo.ProjectRepository;
import com.intertec.autoops.core.repo.RunRepository;
import com.intertec.autoops.core.repo.ScmConfigRepository;
import com.intertec.autoops.core.service.WorkflowComplexity.ComplexityRules;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.EnumMap;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * The governance layer: a policy catalog evaluated live against the
 * tenant's real data. Violations are never stored — fixing the cause
 * clears them on the next read. Policies in ENFORCED mode have teeth:
 * {@link #assertJobRunAllowed}/{@link #assertWorkflowRunAllowed} block
 * MANUAL runs in violating projects (the cron scheduler is not blocked,
 * same trade-off as the approval gate). Policy mode changes are ADMIN-only
 * mutations gated on the GOVERNANCE plan feature; the summary is a read
 * and never gated.
 */
@Service
public class GovernanceService {

    public static final String FEATURE = "GOVERNANCE";

    /** Failure-rate window and threshold for FAILURE_BUDGET. */
    static final int FAILURE_WINDOW_DAYS = 30;
    static final double FAILURE_THRESHOLD = 0.25;
    /** Below this many finished runs a project's failure rate is noise, not signal. */
    static final int FAILURE_MIN_RUNS = 4;
    /** APPROVAL_SLA: a PENDING request older than this is a violation. */
    static final int APPROVAL_SLA_DAYS = 7;

    private static final Logger log = LoggerFactory.getLogger(GovernanceService.class);

    public record Violation(String subject, String detail) {
    }

    public record PolicyView(GovernancePolicy policy, GovernancePolicyMode mode,
                             List<Violation> violations) {
    }

    public record Automation(String name, boolean enabled, String scope,
                             String trigger, String action) {
    }

    public record Summary(Integer complianceScore, int policiesEnforced, int openViolations,
                          Integer quotaUsage, List<Automation> automations,
                          List<PolicyView> policies) {
    }

    private final GovernancePolicyRepository policyRepository;
    private final ProjectRepository projectRepository;
    private final JobRepository jobRepository;
    private final WorkflowClient workflowClient;
    private final CloudConnectionRepository cloudConnectionRepository;
    private final ScmConfigRepository scmConfigRepository;
    private final ApprovalRepository approvalRepository;
    private final RunRepository runRepository;
    private final ComplianceReportRepository complianceReportRepository;
    private final ApprovalSettingsService approvalSettingsService;
    private final SubscriptionInfoClient subscriptionInfoClient;
    private final SubscriptionGate gate;

    public GovernanceService(GovernancePolicyRepository policyRepository,
                             ProjectRepository projectRepository,
                             JobRepository jobRepository,
                             WorkflowClient workflowClient,
                             CloudConnectionRepository cloudConnectionRepository,
                             ScmConfigRepository scmConfigRepository,
                             ApprovalRepository approvalRepository,
                             RunRepository runRepository,
                             ComplianceReportRepository complianceReportRepository,
                             ApprovalSettingsService approvalSettingsService,
                             SubscriptionInfoClient subscriptionInfoClient,
                             SubscriptionGate gate) {
        this.policyRepository = policyRepository;
        this.projectRepository = projectRepository;
        this.jobRepository = jobRepository;
        this.workflowClient = workflowClient;
        this.cloudConnectionRepository = cloudConnectionRepository;
        this.scmConfigRepository = scmConfigRepository;
        this.approvalRepository = approvalRepository;
        this.runRepository = runRepository;
        this.complianceReportRepository = complianceReportRepository;
        this.approvalSettingsService = approvalSettingsService;
        this.subscriptionInfoClient = subscriptionInfoClient;
        this.gate = gate;
    }

    // ------ summary ------

    @Transactional(readOnly = true)
    public Summary summary(String tenantId, String accessToken) {
        List<Project> activeProjects = projectRepository.findByTenantIdOrderByCreatedAtDesc(tenantId)
                .stream().filter(p -> p.getStatus() == ProjectStatus.ACTIVE).toList();
        ComplexityRules rules = approvalSettingsService.rules(tenantId);
        List<PolicyView> policies = evaluatePolicies(tenantId, activeProjects, rules);

        int enforced = (int) policies.stream()
                .filter(p -> p.mode() == GovernancePolicyMode.ENFORCED).count();
        int openViolations = policies.stream()
                .filter(p -> p.mode() != GovernancePolicyMode.DISABLED)
                .mapToInt(p -> p.violations().size()).sum();

        return new Summary(complianceScore(tenantId, activeProjects), enforced, openViolations,
                quotaUsage(tenantId, accessToken), automations(tenantId, activeProjects, rules),
                policies);
    }

    // ------ policy modes ------

    @Transactional(readOnly = true)
    public Map<GovernancePolicy, GovernancePolicyMode> modes(String tenantId) {
        Map<GovernancePolicy, GovernancePolicyMode> stored = new EnumMap<>(GovernancePolicy.class);
        for (GovernancePolicySetting setting : policyRepository.findByTenantId(tenantId)) {
            GovernancePolicy policy = GovernancePolicy.fromCode(setting.getPolicy());
            if (policy != null) {
                stored.put(policy, setting.getMode());
            }
        }
        Map<GovernancePolicy, GovernancePolicyMode> modes = new EnumMap<>(GovernancePolicy.class);
        ComplexityRules rules = null;
        for (GovernancePolicy policy : GovernancePolicy.values()) {
            if (policy == GovernancePolicy.RISKY_APPROVAL) {
                if (rules == null) {
                    rules = approvalSettingsService.rules(tenantId);
                }
                modes.put(policy, rules.riskyTypes().isEmpty()
                        ? GovernancePolicyMode.DISABLED : GovernancePolicyMode.ENFORCED);
            } else if (policy == GovernancePolicy.CREDENTIAL_HYGIENE) {
                modes.put(policy, GovernancePolicyMode.ENFORCED);
            } else {
                modes.put(policy, stored.getOrDefault(policy, policy.defaultMode()));
            }
        }
        return modes;
    }

    @Transactional
    public PolicyView setMode(String tenantId, String actor, String role, String accessToken,
                              String policyCode, String modeCode) {
        if (!ApprovalService.ADMIN_ROLE.equals(role)) {
            throw CoreException.forbidden("governance_admin_only",
                    "Only an admin can change governance policies");
        }
        GovernancePolicy policy = GovernancePolicy.fromCode(policyCode);
        if (policy == null) {
            throw CoreException.badRequest("invalid_policy",
                    "Unknown governance policy: " + policyCode);
        }
        if (!policy.configurable()) {
            throw CoreException.badRequest("policy_not_configurable",
                    policy == GovernancePolicy.RISKY_APPROVAL
                            ? "Risky-operation approval is managed in the approval settings"
                            : "This policy is enforced by the platform and cannot be changed");
        }
        GovernancePolicyMode mode = GovernancePolicyMode.fromCode(modeCode);
        if (mode == null || (mode == GovernancePolicyMode.ENFORCED && !policy.supportsEnforced())) {
            throw CoreException.badRequest("invalid_mode",
                    "Mode must be " + (policy.supportsEnforced()
                            ? "ENFORCED, MONITOR or DISABLED" : "MONITOR or DISABLED"));
        }
        gate.requireFeature(accessToken, FEATURE, "governance policies");

        GovernancePolicySetting setting = policyRepository
                .findByTenantIdAndPolicy(tenantId, policy.name())
                .orElseGet(() -> {
                    GovernancePolicySetting fresh = new GovernancePolicySetting();
                    fresh.setTenantId(tenantId);
                    fresh.setPolicy(policy.name());
                    return fresh;
                });
        setting.setMode(mode);
        setting.setUpdatedBy(actor);
        policyRepository.save(setting);
        log.info("Tenant {} governance policy {} set to {} by {}",
                tenantId, policy, mode, actor);

        List<Project> activeProjects = projectRepository.findByTenantIdOrderByCreatedAtDesc(tenantId)
                .stream().filter(p -> p.getStatus() == ProjectStatus.ACTIVE).toList();
        return new PolicyView(policy, mode,
                mode == GovernancePolicyMode.DISABLED ? List.of()
                        : violationsFor(policy, tenantId, activeProjects));
    }

    // ------ enforcement (manual runs only; the scheduler is not blocked) ------

    @Transactional(readOnly = true)
    public void assertJobRunAllowed(String tenantId, Long jobId) {
        jobRepository.findByIdAndTenantId(jobId, tenantId)
                .map(Job::getProject).map(Project::getId)
                .ifPresent(projectId -> enforce(tenantId, projectId));
    }

    @Transactional(readOnly = true)
    public void assertWorkflowRunAllowed(String tenantId, Long workflowId) {
        workflowClient.find(tenantId, workflowId)
                .map(WorkflowClient.WorkflowView::projectId)
                .ifPresent(projectId -> enforce(tenantId, projectId));
    }

    private void enforce(String tenantId, Long projectId) {
        Map<GovernancePolicy, GovernancePolicyMode> modes = modes(tenantId);
        if (modes.get(GovernancePolicy.SCM_REQUIRED) == GovernancePolicyMode.ENFORCED
                && scmConfigRepository.findByProjectIdAndTenantId(projectId, tenantId).isEmpty()) {
            throw CoreException.forbidden("policy_scm_required",
                    "Governance policy: configure the project's git repository before running "
                            + "(or switch the policy to Monitor)");
        }
        long[] stats = modes.get(GovernancePolicy.FAILURE_BUDGET) == GovernancePolicyMode.ENFORCED
                ? failureStats(tenantId).get(projectId) : null;
        if (stats != null) {
            throw CoreException.forbidden("policy_failure_budget",
                    String.format(Locale.ROOT,
                            "Governance policy: this project failed %d of its last %d runs "
                                    + "(over the 25%% budget) — stabilize it or switch the "
                                    + "policy to Monitor", stats[1], stats[0]));
        }
    }

    // ------ evaluation internals ------

    private List<PolicyView> evaluatePolicies(String tenantId, List<Project> activeProjects,
                                              ComplexityRules rules) {
        Map<GovernancePolicy, GovernancePolicyMode> modes = modes(tenantId);
        List<PolicyView> views = new ArrayList<>();
        for (GovernancePolicy policy : GovernancePolicy.values()) {
            GovernancePolicyMode mode = modes.get(policy);
            views.add(new PolicyView(policy, mode,
                    mode == GovernancePolicyMode.DISABLED ? List.of()
                            : violationsFor(policy, tenantId, activeProjects)));
        }
        return views;
    }

    private List<Violation> violationsFor(GovernancePolicy policy, String tenantId,
                                          List<Project> activeProjects) {
        return switch (policy) {
            case RISKY_APPROVAL -> List.of(); // config-state policy: enforced or not, never "violated"
            case SCM_REQUIRED -> {
                Set<Long> configured = new HashSet<>();
                for (ScmConfig config : scmConfigRepository.findByTenantId(tenantId)) {
                    configured.add(config.getProjectId());
                }
                yield activeProjects.stream()
                        .filter(p -> !configured.contains(p.getId()))
                        .map(p -> new Violation(p.getName(),
                                "No git repository configured for this project"))
                        .toList();
            }
            case CREDENTIAL_HYGIENE -> cloudConnectionRepository
                    .findByTenantIdOrderByCreatedAtDesc(tenantId).stream()
                    .filter(c -> c.getStatus() == ConnectionStatus.DISCONNECTED
                            && c.getCredentialsEnc() != null)
                    .map(c -> new Violation(c.getName() + " (" + c.getPlatform() + ")",
                            "Disconnected integration still holds stored credentials"))
                    .toList();
            case FAILURE_BUDGET -> {
                Map<Long, long[]> stats = failureStats(tenantId);
                List<Violation> violations = new ArrayList<>();
                for (Project project : activeProjects) {
                    long[] s = stats.get(project.getId());
                    if (s != null) {
                        violations.add(new Violation(project.getName(),
                                String.format(Locale.ROOT,
                                        "%d of %d runs failed in the last %d days (%.0f%%)",
                                        s[1], s[0], FAILURE_WINDOW_DAYS, 100.0 * s[1] / s[0])));
                    }
                }
                yield violations;
            }
            case APPROVAL_SLA -> {
                Instant cutoff = Instant.now().minus(Duration.ofDays(APPROVAL_SLA_DAYS));
                yield approvalRepository
                        .findTop100ByTenantIdAndStatusAndCreatedAtBeforeOrderByCreatedAtAsc(
                                tenantId, ApprovalStatus.PENDING, cutoff).stream()
                        .map(a -> new Violation(a.getTargetName(),
                                "Pending for " + Duration.between(a.getCreatedAt(), Instant.now())
                                        .toDays() + " days (requested by " + a.getRequestedBy() + ")"))
                        .toList();
            }
        };
    }

    /** projectId → [finishedRuns, failedRuns] for projects OVER the failure budget. */
    private Map<Long, long[]> failureStats(String tenantId) {
        Instant since = Instant.now().minus(Duration.ofDays(FAILURE_WINDOW_DAYS));
        Map<Long, long[]> over = new HashMap<>();
        for (RunRepository.ProjectRunStatsRow row : runRepository.failureStatsByProject(
                tenantId, since, List.of(RunStatus.SUCCEEDED, RunStatus.FAILED), RunStatus.FAILED)) {
            if (row.getTotal() >= FAILURE_MIN_RUNS
                    && (double) row.getFailed() / row.getTotal() > FAILURE_THRESHOLD) {
                over.put(row.getProjectId(), new long[]{row.getTotal(), row.getFailed()});
            }
        }
        return over;
    }

    private Integer complianceScore(String tenantId, List<Project> activeProjects) {
        Set<Long> activeIds = new HashSet<>();
        for (Project project : activeProjects) {
            activeIds.add(project.getId());
        }
        Map<Long, Integer> latestPerProject = new HashMap<>();
        for (ComplianceReport report : complianceReportRepository
                .findTop200ByTenantIdOrderByCreatedAtDesc(tenantId)) {
            if (activeIds.contains(report.getProjectId())) {
                latestPerProject.putIfAbsent(report.getProjectId(), report.getScore());
            }
        }
        if (latestPerProject.isEmpty()) {
            return null;
        }
        return (int) Math.round(latestPerProject.values().stream()
                .mapToInt(Integer::intValue).average().orElse(0));
    }

    private Integer quotaUsage(String tenantId, String accessToken) {
        PlanLimits limits = subscriptionInfoClient.planLimits(tenantId, accessToken);
        Integer usage = null;
        usage = maxUsage(usage, projectRepository.countByTenantIdAndStatus(
                tenantId, ProjectStatus.ACTIVE), limits.maxProjects());
        usage = maxUsage(usage, workflowClient.countForTenant(tenantId),
                limits.maxAutomations());
        usage = maxUsage(usage, jobRepository.countByTenantId(tenantId), limits.maxJobs());
        usage = maxUsage(usage, cloudConnectionRepository.countByTenantIdAndStatus(
                tenantId, ConnectionStatus.CONNECTED), limits.maxCloudIntegrations());
        return usage;
    }

    private static Integer maxUsage(Integer current, long count, Integer max) {
        if (max == null || max == 0) {
            return current;
        }
        int pct = (int) Math.round(100.0 * count / max);
        return current == null || pct > current ? pct : current;
    }

    private List<Automation> automations(String tenantId, List<Project> activeProjects,
                                         ComplexityRules rules) {
        boolean gating = !rules.riskyTypes().isEmpty();
        boolean scheduling = jobRepository.existsByTenantIdAndEnabledTrueAndScheduleNotNull(tenantId);
        Set<Long> configured = new HashSet<>();
        for (ScmConfig config : scmConfigRepository.findByTenantId(tenantId)) {
            configured.add(config.getProjectId());
        }
        long scmProjects = activeProjects.stream()
                .filter(p -> configured.contains(p.getId())).count();
        return List.of(
                new Automation("Approval gating", gating,
                        gating ? "Risky types: " + String.join(", ", rules.riskyTypes())
                                : "Risky-type gating disabled",
                        "Run request on risky or complex workflows",
                        "Queue an admin approval before execution"),
                new Automation("Scheduled job runner", scheduling,
                        scheduling ? "Jobs with cron schedules" : "No scheduled jobs",
                        "Cron schedule (UTC, 30s poller)",
                        "Launch runs automatically"),
                new Automation("Credential purge", true,
                        "All cloud integrations",
                        "Integration disconnect",
                        "Delete stored credentials immediately"),
                new Automation("Git definition sync", scmProjects > 0,
                        scmProjects + " of " + activeProjects.size() + " projects connected",
                        "Manual export / import",
                        "Version job & workflow definitions in git"));
    }
}