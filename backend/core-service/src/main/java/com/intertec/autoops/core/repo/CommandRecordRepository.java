package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.CommandRecord;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface CommandRecordRepository extends JpaRepository<CommandRecord, Long> {

    List<CommandRecord> findTop100ByTenantIdOrderByCreatedAtDesc(String tenantId);
}
