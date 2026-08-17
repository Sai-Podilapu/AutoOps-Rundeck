package com.intertec.autoops.subscription.web;

import com.intertec.autoops.subscription.repo.PlanRepository;
import com.intertec.autoops.subscription.web.dto.PlanResponse;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/** Public plan catalog (the pricing page browses this pre-auth). */
@RestController
@RequestMapping("/api/plans")
public class PlanController {

    private final PlanRepository planRepository;

    public PlanController(PlanRepository planRepository) {
        this.planRepository = planRepository;
    }

    @GetMapping
    public List<PlanResponse> list() {
        return planRepository.findByActiveTrueOrderBySortOrderAsc().stream()
                .map(PlanResponse::from)
                .toList();
    }
}
