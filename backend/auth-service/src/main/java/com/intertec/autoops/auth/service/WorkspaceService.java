package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.domain.AuditEventType;
import com.intertec.autoops.auth.domain.Tenant;
import com.intertec.autoops.auth.exception.AuthException;
import com.intertec.autoops.auth.repo.TenantRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Optional;

/**
 * Workspace display names. The tenant_id slug is permanent (it is inside
 * every issued token and foreign to other services); only the human-readable
 * name is mutable. Tenants created before V5 have no stored name — callers
 * fall back to prettifying the slug.
 */
@Service
public class WorkspaceService {

    private static final Logger log = LoggerFactory.getLogger(WorkspaceService.class);
    private static final int MAX_NAME_LENGTH = 128;

    private final TenantRepository tenantRepository;
    private final AuditService auditService;

    public WorkspaceService(TenantRepository tenantRepository, AuditService auditService) {
        this.tenantRepository = tenantRepository;
        this.auditService = auditService;
    }

    /** Stores the name typed at sign-up (or a neutral default) for a fresh tenant. */
    @Transactional
    public void record(String tenantId, String requestedName) {
        Tenant tenant = new Tenant();
        tenant.setTenantId(tenantId);
        tenant.setDisplayName(normalize(requestedName));
        tenantRepository.save(tenant);
    }

    @Transactional(readOnly = true)
    public Optional<String> displayName(String tenantId) {
        return tenantRepository.findById(tenantId).map(Tenant::getDisplayName);
    }

    /** Is this corporate domain already claimed by an organization? */
    @Transactional(readOnly = true)
    public boolean domainClaimed(String domain) {
        return domain != null && tenantRepository.existsByEmailDomain(domain);
    }

    /**
     * Claims the verifier's corporate email domain for their tenant — called
     * only AFTER the email is verified (register/verify step or a
     * provider-verified social sign-up), so an unverifiable squatter can
     * never lock a company out. Free-provider emails claim nothing. The
     * unique index is the backstop for two concurrent verifications:
     * the loser gets {@code company_exists}.
     *
     * <p>REQUIRES_NEW so a lost race rolls back only the claim, not the
     * caller's already-completed activation.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void claimDomain(String tenantId, String verifiedEmail) {
        String domain = FreeEmailDomains.corporateDomain(verifiedEmail);
        if (domain == null) {
            return;
        }
        Tenant tenant = tenantRepository.findById(tenantId).orElseGet(() -> {
            // Pre-V5 tenant: claiming creates its row.
            Tenant created = new Tenant();
            created.setTenantId(tenantId);
            created.setDisplayName("My Workspace");
            return created;
        });
        if (domain.equals(tenant.getEmailDomain())) {
            return; // already ours
        }
        if (tenant.getEmailDomain() == null && tenantRepository.existsByEmailDomain(domain)) {
            throw companyExists(domain);
        }
        if (tenant.getEmailDomain() == null) {
            tenant.setEmailDomain(domain);
            try {
                tenantRepository.saveAndFlush(tenant);
                log.info("Tenant {} claimed email domain {}", tenantId, domain);
            } catch (DataIntegrityViolationException ex) {
                throw companyExists(domain); // concurrent verify lost the race
            }
        }
        // Tenant already claimed a different domain (admin-onboarded mixed
        // domains): keep the original claim, nothing to do.
    }

    public static AuthException companyExists(String domain) {
        return AuthException.conflict("company_exists",
                "An organization for @" + domain + " already exists. "
                        + "Ask your workspace admin to invite you instead.");
    }

    /** Admin-only rename (enforced by the caller from the JWT role claim). */
    @Transactional
    public String rename(String tenantId, String newName, Long userId, String email,
                         String ipAddress, String userAgent) {
        String name = normalize(newName);
        Tenant tenant = tenantRepository.findById(tenantId).orElseGet(() -> {
            // Pre-V5 tenant: first rename creates its row.
            Tenant created = new Tenant();
            created.setTenantId(tenantId);
            return created;
        });
        String previous = tenant.getDisplayName();
        tenant.setDisplayName(name);
        tenantRepository.save(tenant);
        auditService.record(AuditEventType.WORKSPACE_RENAMED, userId, email, tenantId, null,
                ipAddress, userAgent, previous != null ? previous + " -> " + name : name);
        log.info("Tenant {} renamed workspace", tenantId);
        return name;
    }

    private String normalize(String name) {
        String trimmed = name == null ? "" : name.trim();
        if (trimmed.isEmpty()) {
            return "My Workspace";
        }
        if (trimmed.length() > MAX_NAME_LENGTH) {
            throw AuthException.badRequest("name_too_long",
                    "Workspace name must be at most " + MAX_NAME_LENGTH + " characters");
        }
        return trimmed;
    }
}
