package com.intertec.autoops.rundeck.service;

import com.intertec.autoops.rundeck.config.RundeckProperties;
import com.intertec.autoops.rundeck.domain.RundeckProject;
import com.intertec.autoops.rundeck.exception.RundeckException;
import com.intertec.autoops.rundeck.repo.RundeckProjectRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Locale;

/**
 * Maps an AutoOps (tenant, project) onto its own Rundeck project, creating it
 * on first use.
 *
 * <p><strong>This class is the tenant boundary.</strong> One Rundeck now serves
 * every customer, so the thing that stops tenant A running a job in tenant B's
 * fleet is no longer a separate credential — it is that every execution is
 * addressed to a project name computed from A's own JWT claim.
 *
 * <p>Three properties make that hold, and all three are worth stating because
 * each was a way to break it:
 * <ul>
 *   <li>the name is <strong>computed, never accepted</strong> — no method here
 *       takes a Rundeck project name as an argument;
 *   <li>the tenant id is <strong>sanitized and length-bounded</strong>, so a
 *       hostile workspace name cannot smuggle a path segment, a wildcard, or
 *       another tenant's prefix into it;
 *   <li>the mapping table has a <strong>unique key on the Rundeck name</strong>,
 *       so even a careless future change to the naming function cannot collapse
 *       two AutoOps projects onto one Rundeck project — it fails loudly instead.
 * </ul>
 */
@Service
public class ProjectProvisioner {

    private static final Logger log = LoggerFactory.getLogger(ProjectProvisioner.class);

    /**
     * Rundeck accepts a fairly permissive project name, but this is narrower on
     * purpose: anything outside it is replaced before it can mean something to
     * a path, a filter or an ACL glob.
     */
    private static final int MAX_TENANT_SEGMENT = 48;

    private final RundeckProjectRepository repository;
    private final PlatformRundeck platform;
    private final com.intertec.autoops.rundeck.client.RundeckApiClient apiClient;
    private final RundeckProperties.Platform settings;

    public ProjectProvisioner(RundeckProjectRepository repository,
                              PlatformRundeck platform,
                              com.intertec.autoops.rundeck.client.RundeckApiClient apiClient,
                              RundeckProperties properties) {
        this.repository = repository;
        this.platform = platform;
        this.apiClient = apiClient;
        this.settings = properties.getPlatform();
    }

    /**
     * The Rundeck project this (tenant, project) executes in, creating it if
     * this is the first step ever run there.
     *
     * <p>REQUIRES_NEW so the mapping row commits independently of whatever run
     * is in flight. A step that fails after provisioning must not roll back the
     * fact that the Rundeck project now exists — the next attempt would then
     * try to create it again and take the 409 path for no reason.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public String ensureProject(String tenantId, Long projectId) {
        if (tenantId == null || tenantId.isBlank()) {
            throw RundeckException.badRequest("missing_tenant", "tenantId is required");
        }
        if (projectId == null) {
            // Ad-hoc commands have no project in AutoOps. They still need
            // somewhere to run, and it must not be a shared bucket — that would
            // put two tenants' ad-hoc output in one Rundeck project.
            throw RundeckException.badRequest("missing_project",
                    "A project is required — every execution is scoped to one");
        }

        RundeckProject mapping = repository.findByTenantIdAndProjectId(tenantId, projectId)
                .orElseGet(() -> create(tenantId, projectId));

        if (mapping.isProvisioned()) {
            return mapping.getRundeckProject();
        }

        try {
            // Idempotent: Rundeck answers 409 when the project already exists,
            // which the client maps to a conflict. That is a SUCCESS here — the
            // desired state is "it exists", not "we created it".
            apiClient.ensureProject(platform.target(), mapping.getRundeckProject());
            mapping.setProvisioned(true);
            mapping.setLastError(null);
        } catch (RundeckException ex) {
            mapping.setLastError(truncate(ex.getMessage()));
            mapping.setUpdatedAt(Instant.now());
            repository.save(mapping);
            log.warn("Could not provision Rundeck project {}: {}",
                    mapping.getRundeckProject(), ex.getMessage());
            throw ex;
        }
        mapping.setUpdatedAt(Instant.now());
        repository.save(mapping);
        return mapping.getRundeckProject();
    }

    /**
     * Forget that a project was ever provisioned, so the next
     * {@link #ensureProject} recreates it on the engine.
     *
     * <p>Exists because the engine is not ours alone to change. An operator can
     * delete a project directly in Rundeck's own UI — that happened during
     * development, and the mapping row went on claiming {@code provisioned=1}
     * for a project that no longer existed. {@code ensureProject} trusts the
     * flag and returns early, so every subsequent step failed with "Project
     * does not exist" and nothing ever repaired it.
     *
     * <p>Called from the dispatch path on a 404, not on a timer: drift is rare,
     * and paying an existence check before every step would tax the common case
     * to detect the uncommon one.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void markUnprovisioned(String tenantId, Long projectId) {
        repository.findByTenantIdAndProjectId(tenantId, projectId).ifPresent(mapping -> {
            mapping.setProvisioned(false);
            mapping.setUpdatedAt(Instant.now());
            repository.save(mapping);
            log.warn("Rundeck project {} is gone from the engine — will re-provision on next use",
                    mapping.getRundeckProject());
        });
    }

    /**
     * Make the engine's copy of this project's NAME match what the tenant sees
     * in AutoOps, without touching the identifier the isolation argument rests
     * on.
     *
     * <p>The Rundeck project {@code name} stays {@code autoops-<tenant>-<id>}
     * forever. It is computed, sanitized and unique-keyed precisely so a
     * workspace name the customer typed cannot reach an ACL glob or a URL path
     * segment — renaming it to a display string would hand that back. Rundeck
     * also cannot rename a project in place, so "matching names" via {@code name}
     * would mean delete-and-recreate and the loss of all execution history.
     *
     * <p>{@code project.label} is the field Rundeck's own UI renders in place of
     * the name when it is set, which is exactly the requirement, so the display
     * name lives there and the identifier is left alone.
     *
     * <p>Best-effort by design: a label is cosmetic and must never be the reason
     * a project cannot be created or a step cannot run.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void syncMetadata(String tenantId, Long projectId, String label, String description) {
        RundeckProject mapping = repository.findByTenantIdAndProjectId(tenantId, projectId)
                .orElse(null);
        if (mapping == null || !mapping.isProvisioned()) {
            return;
        }
        try {
            apiClient.setProjectConfigKey(platform.target(), mapping.getRundeckProject(),
                    "project.label", label);
            apiClient.setProjectConfigKey(platform.target(), mapping.getRundeckProject(),
                    "project.description", description);
        } catch (RundeckException ex) {
            log.warn("Could not sync label onto Rundeck project {}: {}",
                    mapping.getRundeckProject(), ex.getMessage());
        }
    }

    /**
     * Archive: delete the Rundeck project outright, then forget the mapping.
     *
     * <p><strong>This destroys the project's execution history</strong> — every
     * run ever dispatched into it. That is a deliberate product decision, not an
     * oversight: the Rundeck list is to mirror the tenant's ACTIVE projects
     * exactly. Since AutoOps offers <em>restore</em> rather than delete, the
     * mapping row is removed too, so a later restore re-provisions a fresh
     * project instead of pointing at a name that no longer exists.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void archive(String tenantId, Long projectId) {
        RundeckProject mapping = repository.findByTenantIdAndProjectId(tenantId, projectId)
                .orElse(null);
        if (mapping == null) {
            return;
        }
        if (mapping.isProvisioned()) {
            // Let this throw. Deleting the mapping while the engine still holds
            // the project would orphan it permanently: the name is derived, so
            // the next provision would take the 409 path and silently adopt a
            // project full of the archived tenant's executions.
            apiClient.deleteProject(platform.target(), mapping.getRundeckProject());
        }
        repository.delete(mapping);
        log.info("Archived tenant {} project {} — removed Rundeck project {}",
                tenantId, projectId, mapping.getRundeckProject());
    }

    private RundeckProject create(String tenantId, Long projectId) {
        RundeckProject mapping = new RundeckProject();
        mapping.setTenantId(tenantId);
        mapping.setProjectId(projectId);
        mapping.setRundeckProject(projectName(tenantId, projectId));
        try {
            return repository.save(mapping);
        } catch (DataIntegrityViolationException ex) {
            // Two steps of the same run racing on first use. The unique key
            // decides; the loser reads the winner's row rather than failing a
            // job for a benign race.
            return repository.findByTenantIdAndProjectId(tenantId, projectId)
                    .orElseThrow(() -> ex);
        }
    }

    /**
     * {@code autoops-<tenant>-<projectId>}.
     *
     * <p>The project id is the last segment and is numeric, so the name is
     * unambiguous even if a sanitized tenant id ends in a digit. Two different
     * tenants cannot collide: their segments differ, and if sanitizing ever made
     * them equal, the unique key on the name would reject the second one instead
     * of silently sharing.
     */
    String projectName(String tenantId, Long projectId) {
        return settings.getProjectPrefix() + "-" + sanitize(tenantId) + "-" + projectId;
    }

    /**
     * Reduces a tenant id to {@code [a-z0-9-]}, collapses runs of separators and
     * bounds the length.
     *
     * <p>A tenant id is derived from a workspace name the customer typed, so it
     * is untrusted input that ends up in a URL path segment and, later, in ACL
     * globs. Dots, slashes, spaces and wildcards are all removed rather than
     * escaped — escaping is per-context and this value crosses several.
     */
    static String sanitize(String tenantId) {
        String lower = tenantId.toLowerCase(Locale.ROOT);
        StringBuilder out = new StringBuilder(lower.length());
        boolean lastWasDash = false;
        for (int i = 0; i < lower.length() && out.length() < MAX_TENANT_SEGMENT; i++) {
            char c = lower.charAt(i);
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
                out.append(c);
                lastWasDash = false;
            } else if (!lastWasDash && out.length() > 0) {
                out.append('-');
                lastWasDash = true;
            }
        }
        while (out.length() > 0 && out.charAt(out.length() - 1) == '-') {
            out.setLength(out.length() - 1);
        }
        // A tenant id of only punctuation would otherwise produce "autoops--7",
        // which is legal but reads as a bug and sorts oddly next to real ones.
        return out.length() == 0 ? "t" : out.toString();
    }

    private static String truncate(String value) {
        if (value == null) {
            return null;
        }
        return value.length() > 500 ? value.substring(0, 497) + "..." : value;
    }
}
