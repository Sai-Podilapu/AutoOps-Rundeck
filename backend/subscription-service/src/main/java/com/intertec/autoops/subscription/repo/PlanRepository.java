package com.intertec.autoops.subscription.repo;

import com.intertec.autoops.subscription.domain.Plan;
import com.intertec.autoops.subscription.domain.PlanCode;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface PlanRepository extends JpaRepository<Plan, Long> {

    Optional<Plan> findByCode(PlanCode code);

    List<Plan> findByActiveTrueOrderBySortOrderAsc();
}
