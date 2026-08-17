package com.intertec.autoops.core.service;

import com.intertec.autoops.core.domain.Project;
import com.intertec.autoops.core.domain.ProjectStatus;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.ProjectRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * Tenant-scoped project lifecycle. Every MUTATION passes the subscription
 * gate; creates and restores additionally pass the MAX_PROJECTS quota
 * (counted over ACTIVE projects — archiving frees a slot). Reads are never
 * gated: a tenant can always see its own data, whatever its subscription
 * status.
 */
@Service
public class ProjectService {

    private static final Logger log = LoggerFactory.getLogger(ProjectService.class);

    private final ProjectRepository projectRepository;
    private final SubscriptionGate gate;

    public ProjectService(ProjectRepository projectRepository, SubscriptionGate gate) {
        this.projectRepository = projectRepository;
        this.gate = gate;
    }

    @Transactional(readOnly = true)
    public List<Project> list(String tenantId) {
        return projectRepository.findByTenantIdOrderByCreatedAtDesc(tenantId);
    }

    @Transactional(readOnly = true)
    public Project get(String tenantId, Long id) {
        return projectRepository.findByIdAndTenantId(id, tenantId)
                .orElseThrow(() -> CoreException.notFound("project_not_found", "No such project"));
    }

    @Transactional
    public Project create(String tenantId, String actor, String accessToken,
                          String name, String description) {
        if (projectRepository.existsByTenantIdAndNameAndStatus(tenantId, name, ProjectStatus.ACTIVE)) {
            throw CoreException.conflict("project_exists", "An active project with this name already exists");
        }
        long active = projectRepository.countByTenantIdAndStatus(tenantId, ProjectStatus.ACTIVE);
        gate.requireQuota(accessToken, "MAX_PROJECTS", active, "projects");

        Project project = new Project();
        project.setTenantId(tenantId);
        project.setName(name);
        project.setDescription(description);
        project.setCreatedBy(actor);
        Project saved = projectRepository.save(project);
        log.info("Tenant {} created project {}", tenantId, saved.getId());
        return saved;
    }

    @Transactional
    public Project update(String tenantId, String accessToken, Long id,
                          String name, String description) {
        gate.requireActive(accessToken);
        Project project = get(tenantId, id);
        if (name != null && !name.isBlank()) {
            project.setName(name);
        }
        if (description != null) {
            project.setDescription(description);
        }
        return projectRepository.save(project);
    }

    /** Archiving frees a MAX_PROJECTS slot; the data survives. */
    @Transactional
    public Project archive(String tenantId, String accessToken, Long id) {
        gate.requireActive(accessToken);
        Project project = get(tenantId, id);
        project.setStatus(ProjectStatus.ARCHIVED);
        return projectRepository.save(project);
    }

    /** Restoring re-enters the quota — it must pass MAX_PROJECTS again. */
    @Transactional
    public Project restore(String tenantId, String accessToken, Long id) {
        Project project = get(tenantId, id);
        if (project.getStatus() == ProjectStatus.ACTIVE) {
            return project;
        }
        long active = projectRepository.countByTenantIdAndStatus(tenantId, ProjectStatus.ACTIVE);
        gate.requireQuota(accessToken, "MAX_PROJECTS", active, "projects");
        project.setStatus(ProjectStatus.ACTIVE);
        return projectRepository.save(project);
    }
}
