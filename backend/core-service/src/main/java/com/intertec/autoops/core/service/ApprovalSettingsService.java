package com.intertec.autoops.core.service;

import com.intertec.autoops.core.domain.ApprovalSetting;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.ApprovalSettingRepository;
import com.intertec.autoops.core.service.WorkflowComplexity.ComplexityRules;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Per-tenant workflow-complexity rules: the node threshold AND the risky
 * node-type set. No stored row (or NULL risky_types) = platform defaults
 * ({@link WorkflowComplexity}). An EMPTY risky list is a deliberate opt-out
 * of risky-type gating — the node threshold still applies. Reading is open
 * to the tenant; changing is ADMIN-only. Updates are partial: a null field
 * in the request leaves that knob unchanged.
 */
@Service
public class ApprovalSettingsService {

    public static final int MIN_THRESHOLD = 1;
    public static final int MAX_THRESHOLD = 500;
    public static final int MAX_RISKY_TYPES = 50;

    private static final Pattern TYPE_PATTERN = Pattern.compile("^[a-z0-9_-]{1,32}$");
    private static final Logger log = LoggerFactory.getLogger(ApprovalSettingsService.class);

    private final ApprovalSettingRepository repository;

    public ApprovalSettingsService(ApprovalSettingRepository repository) {
        this.repository = repository;
    }

    @Transactional(readOnly = true)
    public ComplexityRules rules(String tenantId) {
        return repository.findById(tenantId)
                .map(ApprovalSettingsService::toRules)
                .orElse(ComplexityRules.PLATFORM_DEFAULTS);
    }

    @Transactional(readOnly = true)
    public ApprovalSetting get(String tenantId) {
        return repository.findById(tenantId).orElseGet(() -> {
            ApprovalSetting defaults = new ApprovalSetting();
            defaults.setTenantId(tenantId);
            defaults.setComplexNodeThreshold(WorkflowComplexity.NODE_THRESHOLD);
            defaults.setRiskyTypes(null); // NULL = platform default set
            return defaults; // not persisted: "no row" keeps meaning "default"
        });
    }

    /** Partial update: null threshold or null riskyTypes = leave unchanged. */
    @Transactional
    public ApprovalSetting update(String tenantId, String actor, String role,
                                  Integer threshold, List<String> riskyTypes) {
        if (!ApprovalService.ADMIN_ROLE.equals(role)) {
            throw CoreException.forbidden("approval_admin_only",
                    "Only an admin can change approval settings");
        }
        if (threshold == null && riskyTypes == null) {
            throw CoreException.badRequest("nothing_to_update",
                    "Provide complexNodeThreshold and/or riskyTypes");
        }
        if (threshold != null && (threshold < MIN_THRESHOLD || threshold > MAX_THRESHOLD)) {
            throw CoreException.badRequest("invalid_threshold",
                    "Threshold must be between " + MIN_THRESHOLD + " and " + MAX_THRESHOLD);
        }
        String riskyCsv = riskyTypes != null ? normalizeRiskyTypes(riskyTypes) : null;

        ApprovalSetting setting = repository.findById(tenantId).orElseGet(() -> {
            ApprovalSetting fresh = new ApprovalSetting();
            fresh.setTenantId(tenantId);
            fresh.setComplexNodeThreshold(WorkflowComplexity.NODE_THRESHOLD);
            return fresh;
        });
        if (threshold != null) {
            setting.setComplexNodeThreshold(threshold);
        }
        if (riskyCsv != null) {
            setting.setRiskyTypes(riskyCsv);
        }
        setting.setUpdatedBy(actor);
        ApprovalSetting saved = repository.save(setting);
        log.info("Tenant {} approval rules set to threshold={} risky=[{}] by {}",
                tenantId, saved.getComplexNodeThreshold(),
                saved.getRiskyTypes() == null ? "<default>" : saved.getRiskyTypes(), actor);
        return saved;
    }

    // ------------------------------------------------------------------

    /** Effective risky set for a stored row (NULL = platform default). */
    public static Set<String> effectiveRiskyTypes(ApprovalSetting setting) {
        return parseRiskyCsv(setting.getRiskyTypes());
    }

    static ComplexityRules toRules(ApprovalSetting setting) {
        return new ComplexityRules(setting.getComplexNodeThreshold(),
                parseRiskyCsv(setting.getRiskyTypes()));
    }

    private static Set<String> parseRiskyCsv(String csv) {
        if (csv == null) {
            return WorkflowComplexity.RISKY_TYPES;
        }
        if (csv.isBlank()) {
            return Set.of(); // explicit opt-out
        }
        Set<String> types = new LinkedHashSet<>();
        for (String part : csv.split(",")) {
            if (!part.isBlank()) {
                types.add(part.trim());
            }
        }
        return types;
    }

    /** Dedup + lowercase + validate; returns the CSV to store ("" = opt-out). */
    private static String normalizeRiskyTypes(List<String> riskyTypes) {
        Set<String> cleaned = new LinkedHashSet<>();
        for (String raw : riskyTypes) {
            if (raw == null || raw.isBlank()) {
                continue;
            }
            String type = raw.trim().toLowerCase();
            if (!TYPE_PATTERN.matcher(type).matches()) {
                throw CoreException.badRequest("invalid_risky_type",
                        "Node types must be 1-32 chars of a-z, 0-9, '-' or '_': " + raw);
            }
            cleaned.add(type);
        }
        if (cleaned.size() > MAX_RISKY_TYPES) {
            throw CoreException.badRequest("too_many_risky_types",
                    "At most " + MAX_RISKY_TYPES + " node types");
        }
        return String.join(",", cleaned);
    }
}
