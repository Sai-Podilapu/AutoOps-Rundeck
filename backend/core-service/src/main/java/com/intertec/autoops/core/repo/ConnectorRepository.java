package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.Connector;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface ConnectorRepository extends JpaRepository<Connector, Long> {

    List<Connector> findByTenantIdOrderByCreatedAtDesc(String tenantId);

    Optional<Connector> findByIdAndTenantId(Long id, String tenantId);
}
