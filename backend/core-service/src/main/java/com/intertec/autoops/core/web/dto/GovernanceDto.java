package com.intertec.autoops.core.web.dto;

import com.intertec.autoops.core.service.GovernanceService;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.util.List;

public final class GovernanceDto {

    private GovernanceDto() {
    }

    public record ModeRequest(@NotBlank @Size(max = 16) String mode) {
    }

    public record ViolationResponse(String subject, String detail) {

        static ViolationResponse from(GovernanceService.Violation v) {
            return new ViolationResponse(v.subject(), v.detail());
        }
    }

    public record PolicyResponse(String code, String name, String scope, String mode,
                                 boolean configurable, boolean supportsEnforced,
                                 List<ViolationResponse> violations) {

        public static PolicyResponse from(GovernanceService.PolicyView view) {
            return new PolicyResponse(view.policy().name(), view.policy().label(),
                    view.policy().scope(), view.mode().name(), view.policy().configurable(),
                    view.policy().supportsEnforced(),
                    view.violations().stream().map(ViolationResponse::from).toList());
        }
    }

    public record AutomationResponse(String name, boolean enabled, String scope,
                                     String trigger, String action) {

        static AutomationResponse from(GovernanceService.Automation a) {
            return new AutomationResponse(a.name(), a.enabled(), a.scope(), a.trigger(), a.action());
        }
    }

    public record SummaryResponse(Integer complianceScore, int policiesEnforced,
                                  int openViolations, Integer quotaUsage,
                                  List<AutomationResponse> automations,
                                  List<PolicyResponse> policies) {

        public static SummaryResponse from(GovernanceService.Summary s) {
            return new SummaryResponse(s.complianceScore(), s.policiesEnforced(),
                    s.openViolations(), s.quotaUsage(),
                    s.automations().stream().map(AutomationResponse::from).toList(),
                    s.policies().stream().map(PolicyResponse::from).toList());
        }
    }
}