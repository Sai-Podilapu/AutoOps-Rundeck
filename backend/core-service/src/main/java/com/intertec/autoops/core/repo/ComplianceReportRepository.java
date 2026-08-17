package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.ComplianceReport;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface ComplianceReportRepository extends JpaRepository<ComplianceReport, Long> {

    /** Tenant isolation: every by-id lookup is scoped to the caller's tenant. */
    Optional<ComplianceReport> findByIdAndTenantId(Long id, String tenantId);

    List<ComplianceReport> findTop100ByTenantIdAndProjectIdOrderByCreatedAtDesc(
            String tenantId, Long projectId);

    /** Governance dashboard basis: newest-first across the tenant (latest per project wins). */
    List<ComplianceReport> findTop200ByTenantIdOrderByCreatedAtDesc(String tenantId);
}