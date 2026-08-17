package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.intertec.autoops.core.client.SubscriptionInfoClient;
import com.intertec.autoops.core.domain.Approval;
import com.intertec.autoops.core.domain.ApprovalStatus;
import com.intertec.autoops.core.domain.CloudConnection;
import com.intertec.autoops.core.domain.ComplianceFramework;
import com.intertec.autoops.core.domain.ComplianceReport;
import com.intertec.autoops.core.domain.ComplianceStatus;
import com.intertec.autoops.core.domain.ConnectionStatus;
import com.intertec.autoops.core.domain.Job;
import com.intertec.autoops.core.domain.Project;
import com.intertec.autoops.core.domain.Run;
import com.intertec.autoops.core.domain.RunStatus;
import com.intertec.autoops.core.domain.ScmConfig;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.ApprovalRepository;
import com.intertec.autoops.core.repo.CloudConnectionRepository;
import com.intertec.autoops.core.repo.ComplianceReportRepository;
import com.intertec.autoops.core.repo.RunRepository;
import com.intertec.autoops.core.repo.ScmConfigRepository;
import com.intertec.autoops.core.client.WorkflowClient;
import com.intertec.autoops.core.service.WorkflowComplexity.ComplexityRules;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Locale;
import java.util.Optional;

/**
 * Generates compliance reports by evaluating a framework's control set
 * against the project's REAL posture: approval gating, segregation of
 * duties in recorded decisions, encrypted cloud credentials, credential
 * purge on disconnect, SCM sync, plan retention depth, and the last 30
 * days of execution history. Findings are snapshotted as JSON on the
 * report row, so a report stays stable as evidence for what was true at
 * generation time. Generation is a mutation gated on the
 * COMPLIANCE_REPORTS plan feature; reads (list/detail/download) are
 * never gated.
 */
@Service
public class ComplianceService {

    public static final String FEATURE = "COMPLIANCE_REPORTS";

    /** Execution-history window the monitoring control looks at. */
    static final int MONITORING_WINDOW_DAYS = 30;
    /** A PENDING approval older than this counts as an un-reviewed backlog item. */
    static final int STALE_APPROVAL_DAYS = 7;

    private static final Logger log = LoggerFactory.getLogger(ComplianceService.class);

    enum CheckKind {
        CHANGE_APPROVAL, SEGREGATION_OF_DUTIES, APPROVAL_BACKLOG,
        CREDENTIAL_ENCRYPTION, CREDENTIAL_REVOCATION, VERSION_CONTROL,
        AUDIT_RETENTION, EXECUTION_MONITORING
    }

    public enum CheckStatus { PASS, WARN, FAIL, NOT_APPLICABLE }

    record Control(String ref, String title, String requirement, CheckKind kind) {
    }

    public record ControlResult(String ref, String title, String requirement,
                                CheckStatus status, String evidence) {
    }

    /** Everything the checks look at, gathered once per generation. */
    record Evidence(int jobsTotal, int jobsGated,
                    int workflowsTotal, int workflowsGated,
                    ComplexityRules rules,
                    int approvalsResolved, int approvalsSelfDecided, int approvalsStale,
                    int connectionsConnected, int connectionsWithCreds,
                    int disconnectedTotal, int disconnectedWithCreds,
                    ScmConfig scm,
                    Integer historyDays,
                    int runsWindow, int runsSucceeded, int runsFailed) {
    }

    /** Retention depth (days) each framework's report expects, per its control set. */
    private static int retentionGuideline(ComplianceFramework framework) {
        return switch (framework) {
            case SOC2, ISO_27001 -> 90;
            case HIPAA -> 180;
            case PCI_DSS -> 365;
            case GDPR -> 30;
        };
    }

    private static List<Control> catalog(ComplianceFramework framework) {
        return switch (framework) {
            case SOC2 -> List.of(
                    new Control("CC8.1", "Change authorization",
                            "Changes to automation are authorized before they run in production.",
                            CheckKind.CHANGE_APPROVAL),
                    new Control("CC5.3", "Segregation of duties",
                            "The person who requests a change is not the one who approves it.",
                            CheckKind.SEGREGATION_OF_DUTIES),
                    new Control("CC7.3", "Timely evaluation",
                            "Pending change requests are reviewed without undue delay.",
                            CheckKind.APPROVAL_BACKLOG),
                    new Control("CC6.1", "Credential protection",
                            "Secrets used to reach cloud environments are encrypted at rest.",
                            CheckKind.CREDENTIAL_ENCRYPTION),
                    new Control("CC6.5", "Access revocation",
                            "Credentials are purged when an integration is decommissioned.",
                            CheckKind.CREDENTIAL_REVOCATION),
                    new Control("A1.2", "Configuration recoverability",
                            "Automation definitions are versioned in source control for recovery.",
                            CheckKind.VERSION_CONTROL),
                    new Control("CC4.1", "Audit evidence retention",
                            "Execution history is retained long enough to serve as audit evidence.",
                            CheckKind.AUDIT_RETENTION),
                    new Control("CC7.2", "Operations monitoring",
                            "Executions are monitored and failures stay within tolerances.",
                            CheckKind.EXECUTION_MONITORING));
            case ISO_27001 -> List.of(
                    new Control("A.8.32", "Change management",
                            "Changes to information processing are subject to approval.",
                            CheckKind.CHANGE_APPROVAL),
                    new Control("A.5.3", "Segregation of duties",
                            "Conflicting duties — requesting and approving — are segregated.",
                            CheckKind.SEGREGATION_OF_DUTIES),
                    new Control("A.8.24", "Use of cryptography",
                            "Stored credentials are protected with strong encryption.",
                            CheckKind.CREDENTIAL_ENCRYPTION),
                    new Control("A.8.10", "Information deletion",
                            "Secrets are deleted when no longer required.",
                            CheckKind.CREDENTIAL_REVOCATION),
                    new Control("A.8.9", "Configuration management",
                            "Configurations are recorded and managed in version control.",
                            CheckKind.VERSION_CONTROL),
                    new Control("A.8.15", "Logging",
                            "Activity logs are produced, kept and protected.",
                            CheckKind.AUDIT_RETENTION),
                    new Control("A.8.16", "Monitoring activities",
                            "Systems are monitored for anomalous behaviour.",
                            CheckKind.EXECUTION_MONITORING));
            case HIPAA -> List.of(
                    new Control("§164.308(a)(4)", "Access authorization",
                            "Access to run protected operations is authorized and documented.",
                            CheckKind.CHANGE_APPROVAL),
                    new Control("§164.308(a)(3)", "Workforce security",
                            "Approval duties are separated from request duties.",
                            CheckKind.SEGREGATION_OF_DUTIES),
                    new Control("§164.312(a)(2)(iv)", "Encryption and decryption",
                            "Stored credentials are encrypted.",
                            CheckKind.CREDENTIAL_ENCRYPTION),
                    new Control("§164.308(a)(3)(ii)(C)", "Termination procedures",
                            "Access secrets are removed when an integration ends.",
                            CheckKind.CREDENTIAL_REVOCATION),
                    new Control("§164.312(c)(1)", "Integrity",
                            "Definitions are protected from improper alteration via versioning.",
                            CheckKind.VERSION_CONTROL),
                    new Control("§164.312(b)", "Audit controls",
                            "Activity records are captured and retained.",
                            CheckKind.AUDIT_RETENTION),
                    new Control("§164.308(a)(1)(ii)(D)", "Activity review",
                            "System activity is regularly reviewed for failures.",
                            CheckKind.EXECUTION_MONITORING));
            case PCI_DSS -> List.of(
                    new Control("Req 6.5.1", "Change control",
                            "Changes follow a documented approval process.",
                            CheckKind.CHANGE_APPROVAL),
                    new Control("Req 6.4.2", "Separation of duties",
                            "Requesters and approvers are separate individuals.",
                            CheckKind.SEGREGATION_OF_DUTIES),
                    new Control("Req 8.6.2", "Credential protection",
                            "Authentication credentials are not stored in clear text.",
                            CheckKind.CREDENTIAL_ENCRYPTION),
                    new Control("Req 8.2.5", "Access revocation",
                            "Access is revoked and secrets removed on decommission.",
                            CheckKind.CREDENTIAL_REVOCATION),
                    new Control("Req 6.3.2", "Configuration inventory",
                            "Custom automation is inventoried and version-controlled.",
                            CheckKind.VERSION_CONTROL),
                    new Control("Req 10.5.1", "Log retention",
                            "Audit history is retained for at least twelve months.",
                            CheckKind.AUDIT_RETENTION),
                    new Control("Req 10.4.1", "Log review",
                            "Execution outcomes are reviewed and failures addressed.",
                            CheckKind.EXECUTION_MONITORING));
            case GDPR -> List.of(
                    new Control("Art. 25", "Data protection by design",
                            "Processing changes are gated behind documented approval.",
                            CheckKind.CHANGE_APPROVAL),
                    new Control("Art. 32(4)", "Processing under authorization",
                            "Operations run only under the authorization of the controller.",
                            CheckKind.SEGREGATION_OF_DUTIES),
                    new Control("Art. 32(1)(a)", "Encryption",
                            "Credentials touching personal data are encrypted.",
                            CheckKind.CREDENTIAL_ENCRYPTION),
                    new Control("Art. 5(1)(e)", "Storage limitation",
                            "Secrets are kept no longer than necessary.",
                            CheckKind.CREDENTIAL_REVOCATION),
                    new Control("Art. 30", "Records of processing",
                            "Processing activity records are kept and retained.",
                            CheckKind.AUDIT_RETENTION),
                    new Control("Art. 32(1)(d)", "Regular testing",
                            "Processing is regularly tested and failures evaluated.",
                            CheckKind.EXECUTION_MONITORING));
        };
    }

    private final ComplianceReportRepository reportRepository;
    private final ProjectService projectService;
    private final JobService jobService;
    private final WorkflowClient workflowClient;
    private final ApprovalSettingsService approvalSettingsService;
    private final ApprovalRepository approvalRepository;
    private final RunRepository runRepository;
    private final CloudConnectionRepository cloudConnectionRepository;
    private final ScmConfigRepository scmConfigRepository;
    private final SubscriptionGate gate;
    private final SubscriptionInfoClient subscriptionInfoClient;
    private final ObjectMapper objectMapper;

    public ComplianceService(ComplianceReportRepository reportRepository,
                             ProjectService projectService,
                             JobService jobService,
                             WorkflowClient workflowClient,
                             ApprovalSettingsService approvalSettingsService,
                             ApprovalRepository approvalRepository,
                             RunRepository runRepository,
                             CloudConnectionRepository cloudConnectionRepository,
                             ScmConfigRepository scmConfigRepository,
                             SubscriptionGate gate,
                             SubscriptionInfoClient subscriptionInfoClient,
                             ObjectMapper objectMapper) {
        this.reportRepository = reportRepository;
        this.projectService = projectService;
        this.jobService = jobService;
        this.workflowClient = workflowClient;
        this.approvalSettingsService = approvalSettingsService;
        this.approvalRepository = approvalRepository;
        this.runRepository = runRepository;
        this.cloudConnectionRepository = cloudConnectionRepository;
        this.scmConfigRepository = scmConfigRepository;
        this.gate = gate;
        this.subscriptionInfoClient = subscriptionInfoClient;
        this.objectMapper = objectMapper;
    }

    // ------ queries ------

    @Transactional(readOnly = true)
    public List<ComplianceReport> list(String tenantId, Long projectId) {
        projectService.get(tenantId, projectId); // 404 if not the tenant's project
        return reportRepository.findTop100ByTenantIdAndProjectIdOrderByCreatedAtDesc(
                tenantId, projectId);
    }

    @Transactional(readOnly = true)
    public ComplianceReport get(String tenantId, Long reportId) {
        return reportRepository.findByIdAndTenantId(reportId, tenantId)
                .orElseThrow(() -> CoreException.notFound("report_not_found",
                        "Compliance report not found"));
    }

    // ------ generation ------

    @Transactional
    public ComplianceReport generate(String tenantId, String actor, String accessToken,
                                     Long projectId, String frameworkCode) {
        ComplianceFramework framework = ComplianceFramework.fromCode(frameworkCode);
        if (framework == null) {
            throw CoreException.badRequest("invalid_framework",
                    "Unknown compliance framework: " + frameworkCode);
        }
        gate.requireFeature(accessToken, FEATURE, "compliance reporting");
        Project project = projectService.get(tenantId, projectId);

        Evidence evidence = collect(tenantId, accessToken, projectId);
        List<ControlResult> results = catalog(framework).stream()
                .map(control -> new ControlResult(control.ref(), control.title(),
                        control.requirement(),
                        evaluate(control.kind(), framework, evidence),
                        evidenceText(control.kind(), framework, evidence)))
                .toList();

        int passed = count(results, CheckStatus.PASS);
        int warnings = count(results, CheckStatus.WARN);
        int failed = count(results, CheckStatus.FAIL);
        int notApplicable = count(results, CheckStatus.NOT_APPLICABLE);
        int applicable = results.size() - notApplicable;
        int score = applicable == 0 ? 100
                : (int) Math.round(100.0 * (passed + 0.5 * warnings) / applicable);
        ComplianceStatus status = failed > 0
                ? ComplianceStatus.NON_COMPLIANT : ComplianceStatus.COMPLIANT;

        ComplianceReport report = new ComplianceReport();
        report.setTenantId(tenantId);
        report.setProjectId(projectId);
        report.setFramework(framework);
        report.setStatus(status);
        report.setScore(score);
        report.setControlsTotal(results.size());
        report.setPassed(passed);
        report.setWarnings(warnings);
        report.setFailed(failed);
        report.setGeneratedBy(actor);
        report.setContent(buildContent(framework, project, actor, status, score,
                results, notApplicable));
        ComplianceReport saved = reportRepository.save(report);
        log.info("Tenant {} project {} generated {} report {} — {} ({} passed/{} warn/{} failed)",
                tenantId, projectId, framework, saved.getId(), status, passed, warnings, failed);
        return saved;
    }

    private Evidence collect(String tenantId, String accessToken, Long projectId) {
        ComplexityRules rules = approvalSettingsService.rules(tenantId);
        List<Job> jobs = jobService.list(tenantId, projectId);
        List<WorkflowClient.WorkflowView> workflows =
                workflowClient.listByProject(tenantId, projectId);
        int jobsGated = (int) jobs.stream().filter(Job::isRequiresApproval).count();
        int workflowsGated = (int) workflows.stream()
                .filter(w -> WorkflowComplexity.isComplex(w.definition(), w.nodeCount(), rules))
                .count();

        Instant now = Instant.now();
        Instant staleBefore = now.minus(Duration.ofDays(STALE_APPROVAL_DAYS));
        List<Approval> approvals = approvalRepository
                .findTop200ByTenantIdAndProjectIdOrderByCreatedAtDesc(tenantId, projectId);
        int resolved = 0;
        int selfDecided = 0;
        int stale = 0;
        for (Approval approval : approvals) {
            if (approval.getStatus() == ApprovalStatus.PENDING) {
                if (approval.getCreatedAt() != null
                        && approval.getCreatedAt().isBefore(staleBefore)) {
                    stale++;
                }
            } else {
                resolved++;
                if (approval.getDecidedBy() != null
                        && approval.getDecidedBy().equalsIgnoreCase(approval.getRequestedBy())) {
                    selfDecided++;
                }
            }
        }

        List<CloudConnection> connections = cloudConnectionRepository
                .findByTenantIdOrderByCreatedAtDesc(tenantId);
        int connected = 0;
        int withCreds = 0;
        int disconnected = 0;
        int disconnectedWithCreds = 0;
        for (CloudConnection connection : connections) {
            if (connection.getStatus() == ConnectionStatus.CONNECTED) {
                connected++;
                if (connection.getCredentialsEnc() != null) {
                    withCreds++;
                }
            } else {
                disconnected++;
                if (connection.getCredentialsEnc() != null) {
                    disconnectedWithCreds++;
                }
            }
        }

        Optional<ScmConfig> scm = scmConfigRepository
                .findByProjectIdAndTenantId(projectId, tenantId);
        Integer historyDays = subscriptionInfoClient.historyDays(tenantId, accessToken);

        Instant windowStart = now.minus(Duration.ofDays(MONITORING_WINDOW_DAYS));
        List<Run> runs = runRepository
                .findTop200ByTenantIdAndProjectIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
                        tenantId, projectId, windowStart);
        int succeeded = (int) runs.stream().filter(r -> r.getStatus() == RunStatus.SUCCEEDED).count();
        int runFailed = (int) runs.stream().filter(r -> r.getStatus() == RunStatus.FAILED).count();

        return new Evidence(jobs.size(), jobsGated, workflows.size(), workflowsGated, rules,
                resolved, selfDecided, stale, connected, withCreds,
                disconnected, disconnectedWithCreds, scm.orElse(null), historyDays,
                runs.size(), succeeded, runFailed);
    }

    // ------ control evaluation ------

    private CheckStatus evaluate(CheckKind kind, ComplianceFramework framework, Evidence e) {
        return switch (kind) {
            case CHANGE_APPROVAL -> {
                if (e.jobsTotal() + e.workflowsTotal() == 0) {
                    yield CheckStatus.NOT_APPLICABLE;
                }
                boolean riskyGatingOff = e.rules().riskyTypes().isEmpty();
                yield riskyGatingOff && e.jobsGated() == 0
                        ? CheckStatus.FAIL : CheckStatus.PASS;
            }
            case SEGREGATION_OF_DUTIES -> e.approvalsSelfDecided() > 0 ? CheckStatus.FAIL
                    : e.approvalsResolved() == 0 ? CheckStatus.NOT_APPLICABLE
                    : CheckStatus.PASS;
            case APPROVAL_BACKLOG -> e.approvalsStale() > 0 ? CheckStatus.WARN : CheckStatus.PASS;
            case CREDENTIAL_ENCRYPTION -> e.connectionsConnected() == 0
                    ? CheckStatus.NOT_APPLICABLE
                    : e.connectionsWithCreds() < e.connectionsConnected()
                            ? CheckStatus.WARN : CheckStatus.PASS;
            case CREDENTIAL_REVOCATION -> e.disconnectedWithCreds() > 0
                    ? CheckStatus.FAIL : CheckStatus.PASS;
            case VERSION_CONTROL -> e.scm() != null ? CheckStatus.PASS : CheckStatus.FAIL;
            case AUDIT_RETENTION -> e.historyDays() == null
                    || e.historyDays() >= retentionGuideline(framework)
                    ? CheckStatus.PASS : CheckStatus.FAIL;
            case EXECUTION_MONITORING -> {
                int finished = e.runsSucceeded() + e.runsFailed();
                if (finished == 0) {
                    yield CheckStatus.NOT_APPLICABLE;
                }
                double failureRate = (double) e.runsFailed() / finished;
                yield failureRate > 0.25 ? CheckStatus.FAIL
                        : failureRate > 0.10 ? CheckStatus.WARN : CheckStatus.PASS;
            }
        };
    }

    private String evidenceText(CheckKind kind, ComplianceFramework framework, Evidence e) {
        return switch (kind) {
            case CHANGE_APPROVAL -> {
                if (e.jobsTotal() + e.workflowsTotal() == 0) {
                    yield "No jobs or workflows exist in this project yet.";
                }
                String risky = e.rules().riskyTypes().isEmpty()
                        ? "risky-type gating is DISABLED for this tenant"
                        : "risky step types " + e.rules().riskyTypes() + " always require approval";
                yield String.format(Locale.ROOT,
                        "%d of %d job(s) require approval; %d of %d workflow(s) are auto-gated "
                                + "(complexity threshold %d nodes; %s).",
                        e.jobsGated(), e.jobsTotal(), e.workflowsGated(), e.workflowsTotal(),
                        e.rules().nodeThreshold(), risky);
            }
            case SEGREGATION_OF_DUTIES -> e.approvalsResolved() == 0
                    ? "No approval decisions recorded for this project yet."
                    : e.approvalsSelfDecided() > 0
                            ? e.approvalsSelfDecided() + " of " + e.approvalsResolved()
                                    + " decided approval(s) were resolved by their own requester."
                            : e.approvalsResolved() + " approval decision(s) on record, each "
                                    + "reviewed by someone other than the requester; only "
                                    + "admins can decide requests.";
            case APPROVAL_BACKLOG -> e.approvalsStale() > 0
                    ? e.approvalsStale() + " approval request(s) have been pending for more than "
                            + STALE_APPROVAL_DAYS + " days."
                    : "No approval requests pending longer than " + STALE_APPROVAL_DAYS + " days.";
            case CREDENTIAL_ENCRYPTION -> {
                if (e.connectionsConnected() == 0) {
                    yield "No cloud connections are configured for this workspace.";
                }
                String base = e.connectionsWithCreds() + " of " + e.connectionsConnected()
                        + " connected integration(s) store credentials, all encrypted with "
                        + "AES-256-GCM at rest; secrets are never returned by the API.";
                yield e.connectionsWithCreds() < e.connectionsConnected()
                        ? base + " " + (e.connectionsConnected() - e.connectionsWithCreds())
                                + " connection(s) hold no stored credentials and rely on "
                                + "ambient access."
                        : base;
            }
            case CREDENTIAL_REVOCATION -> e.disconnectedWithCreds() > 0
                    ? e.disconnectedWithCreds() + " disconnected integration(s) still hold "
                            + "stored credentials."
                    : e.disconnectedTotal() == 0
                            ? "No integrations have been revoked; disconnecting purges stored "
                                    + "credentials by design."
                            : e.disconnectedTotal() + " revoked integration(s), all with "
                                    + "credentials purged.";
            case VERSION_CONTROL -> e.scm() != null
                    ? "Job and workflow definitions sync to " + e.scm().getRepoUrl()
                            + " (branch " + e.scm().getBranch() + ")."
                    : "No source-control repository is configured for this project — set up "
                            + "SCM sync to version automation definitions.";
            case AUDIT_RETENTION -> e.historyDays() == null
                    ? "Execution history retention is unbounded on the current plan."
                    : "Current plan retains execution history for " + e.historyDays()
                            + " days (report guideline for " + framework.label() + ": "
                            + retentionGuideline(framework) + " days).";
            case EXECUTION_MONITORING -> {
                int finished = e.runsSucceeded() + e.runsFailed();
                if (finished == 0) {
                    yield "No finished executions in the last " + MONITORING_WINDOW_DAYS + " days.";
                }
                yield String.format(Locale.ROOT,
                        "%d execution(s) in the last %d days: %d succeeded, %d failed "
                                + "(%.0f%% failure rate). Every run keeps a step-level log.",
                        e.runsWindow(), MONITORING_WINDOW_DAYS, e.runsSucceeded(), e.runsFailed(),
                        100.0 * e.runsFailed() / finished);
            }
        };
    }

    // ------ snapshot + rendering ------

    private String buildContent(ComplianceFramework framework, Project project, String actor,
                                ComplianceStatus status, int score,
                                List<ControlResult> results, int notApplicable) {
        ObjectNode root = objectMapper.createObjectNode();
        root.put("framework", framework.name());
        root.put("frameworkLabel", framework.label());
        ObjectNode projectNode = root.putObject("project");
        projectNode.put("id", project.getId());
        projectNode.put("name", project.getName());
        root.put("generatedBy", actor);
        root.put("generatedAt", Instant.now().toString());
        ObjectNode summary = root.putObject("summary");
        summary.put("status", status.name());
        summary.put("score", score);
        summary.put("total", results.size());
        summary.put("passed", count(results, CheckStatus.PASS));
        summary.put("warnings", count(results, CheckStatus.WARN));
        summary.put("failed", count(results, CheckStatus.FAIL));
        summary.put("notApplicable", notApplicable);
        ArrayNode controls = root.putArray("controls");
        for (ControlResult result : results) {
            ObjectNode node = controls.addObject();
            node.put("ref", result.ref());
            node.put("title", result.title());
            node.put("requirement", result.requirement());
            node.put("status", result.status().name());
            node.put("evidence", result.evidence());
        }
        return root.toString();
    }

    /**
     * Strict-XHTML rendering of a stored report — the PDF source. Must stay
     * well-formed XML with CSS 2.1 only (no flexbox, no named entities):
     * openhtmltopdf parses it as XML.
     */
    String renderHtml(ComplianceReport report) {
        com.fasterxml.jackson.databind.JsonNode content;
        try {
            content = objectMapper.readTree(report.getContent());
        } catch (Exception ex) {
            throw CoreException.badRequest("report_corrupt", "Stored report is not readable");
        }
        StringBuilder html = new StringBuilder();
        String label = report.getFramework().label();
        html.append("<html><head>")
                .append("<title>").append(esc(label)).append(" Compliance Report</title>")
                .append("<style>")
                .append("@page{size:A4;margin:2cm}")
                .append("body{font-family:sans-serif;color:#0f172a;font-size:12px}")
                .append("h1{font-size:22px;margin:0 0 4px 0}")
                .append(".meta{color:#64748b;font-size:11px;margin-bottom:18px}")
                .append("table{width:100%;border-collapse:collapse}")
                .append("table.summary{margin:0 0 18px 0;border:1px solid #e2e8f0}")
                .append("table.summary td{border-bottom:0;text-align:center;padding:10px 8px}")
                .append(".label{font-size:10px;color:#475569;text-transform:uppercase}")
                .append(".value{font-size:17px;font-weight:bold;color:#0f172a}")
                .append("th,td{text-align:left;padding:8px 10px;")
                .append("border-bottom:1px solid #e2e8f0;vertical-align:top}")
                .append("th{font-size:10px;text-transform:uppercase;color:#64748b}")
                .append(".PASS{color:#047857;font-weight:bold}")
                .append(".WARN{color:#b45309;font-weight:bold}")
                .append(".FAIL{color:#b91c1c;font-weight:bold}")
                .append(".NOT_APPLICABLE{color:#64748b}")
                .append(".req{color:#64748b;font-size:10px}")
                .append("</style></head><body>");
        html.append("<h1>").append(esc(label)).append(" Compliance Report</h1>");
        html.append("<div class=\"meta\">Project: ")
                .append(esc(content.path("project").path("name").asText("")))
                .append(" · Generated ").append(esc(content.path("generatedAt").asText("")))
                .append(" by ").append(esc(content.path("generatedBy").asText("")))
                .append(" · Report #").append(report.getId())
                .append("</div>");
        html.append("<table class=\"summary\"><tr>");
        summaryCell(html, "Result",
                report.getStatus() == ComplianceStatus.COMPLIANT ? "Compliant" : "Non-compliant",
                report.getStatus() == ComplianceStatus.COMPLIANT ? "PASS" : "FAIL");
        summaryCell(html, "Score", report.getScore() + "%", null);
        summaryCell(html, "Passed", String.valueOf(report.getPassed()), null);
        summaryCell(html, "Warnings", String.valueOf(report.getWarnings()), null);
        summaryCell(html, "Failed", String.valueOf(report.getFailed()), null);
        summaryCell(html, "Controls", String.valueOf(report.getControlsTotal()), null);
        html.append("</tr></table>");
        html.append("<table><tr><th>Control</th><th>Status</th><th>Evidence</th></tr>");
        for (com.fasterxml.jackson.databind.JsonNode control : content.path("controls")) {
            String status = control.path("status").asText("");
            html.append("<tr><td><b>").append(esc(control.path("ref").asText("")))
                    .append("</b> ").append(esc(control.path("title").asText("")))
                    .append("<div class=\"req\">")
                    .append(esc(control.path("requirement").asText(""))).append("</div></td>")
                    .append("<td class=\"").append(esc(status)).append("\">")
                    .append(esc(statusLabel(status))).append("</td>")
                    .append("<td>").append(esc(control.path("evidence").asText("")))
                    .append("</td></tr>");
        }
        html.append("</table></body></html>");
        return html.toString();
    }

    private static void summaryCell(StringBuilder html, String label, String value,
                                    String valueClass) {
        html.append("<td><div class=\"label\">").append(label).append("</div>")
                .append("<div class=\"value")
                .append(valueClass != null ? " " + valueClass : "")
                .append("\">").append(esc(value)).append("</div></td>");
    }

    /** The downloadable evidence document. */
    public byte[] renderPdf(ComplianceReport report) {
        String xhtml = renderHtml(report);
        try (java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream()) {
            com.openhtmltopdf.pdfboxout.PdfRendererBuilder builder =
                    new com.openhtmltopdf.pdfboxout.PdfRendererBuilder();
            builder.useFastMode();
            builder.withHtmlContent(xhtml, null);
            builder.toStream(out);
            builder.run();
            return out.toByteArray();
        } catch (Exception ex) {
            log.warn("PDF rendering failed for report {}: {}", report.getId(), ex.toString());
            throw CoreException.badRequest("report_render_failed",
                    "Could not render the report as PDF");
        }
    }

    private static String statusLabel(String status) {
        return switch (status) {
            case "PASS" -> "Pass";
            case "WARN" -> "Warning";
            case "FAIL" -> "Fail";
            case "NOT_APPLICABLE" -> "N/A";
            default -> status;
        };
    }

    private static String esc(String text) {
        return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                .replace("\"", "&quot;");
    }

    private static int count(List<ControlResult> results, CheckStatus status) {
        return (int) results.stream().filter(r -> r.status() == status).count();
    }
}