package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.Node;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface NodeRepository extends JpaRepository<Node, Long> {

    List<Node> findByTenantIdAndProjectIdOrderByCreatedAtDesc(String tenantId, Long projectId);

    Optional<Node> findByIdAndTenantId(Long id, String tenantId);

    boolean existsByTenantIdAndProjectIdAndName(String tenantId, Long projectId, String name);
}
