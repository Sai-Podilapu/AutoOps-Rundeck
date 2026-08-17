package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.LibraryItem;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface LibraryItemRepository extends JpaRepository<LibraryItem, Long> {

    /** The platform-managed catalog (tenant_id IS NULL). */
    List<LibraryItem> findByTenantIdIsNullOrderByCreatedAtDesc();

    /** A tenant's own copies/authored templates. */
    List<LibraryItem> findByTenantIdOrderByCreatedAtDesc(String tenantId);

    Optional<LibraryItem> findByIdAndTenantIdIsNull(Long id);

    Optional<LibraryItem> findByIdAndTenantId(Long id, String tenantId);

    boolean existsByTenantIdAndTitleIgnoreCase(String tenantId, String title);
}
