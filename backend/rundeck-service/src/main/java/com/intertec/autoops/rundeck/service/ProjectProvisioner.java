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
