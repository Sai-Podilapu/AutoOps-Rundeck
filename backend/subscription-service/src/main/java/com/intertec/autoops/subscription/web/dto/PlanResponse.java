package com.intertec.autoops.subscription.web.dto;

import com.intertec.autoops.subscription.domain.Feature;
import com.intertec.autoops.subscription.domain.Plan;

import java.util.Set;

public record PlanResponse(
        String code,
        String name,
        String description,
        int priceMonthly,
        Integer maxProjects,
        Integer maxNodes,
        Integer maxAutomations,
        Integer maxJobs,
        Integer maxCloudIntegrations,
        Integer historyDays,
        int trialDays,
        Set<Feature> features) {

    public static PlanResponse from(Plan plan) {
        return new PlanResponse(plan.getCode().name(), plan.getName(), plan.getDescription(),
                plan.getPriceMonthly(), plan.getMaxProjects(), plan.getMaxNodes(),
                plan.getMaxAutomations(), plan.getMaxJobs(), plan.getMaxCloudIntegrations(),
                plan.getHistoryDays(), plan.getTrialDays(), plan.getFeatures());
    }
}
