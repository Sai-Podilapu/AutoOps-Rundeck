package com.intertec.autoops.core.web.dto;

import com.intertec.autoops.core.domain.ApprovalSetting;
import com.intertec.autoops.core.service.ApprovalSettingsService;
import com.intertec.autoops.core.service.WorkflowComplexity;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;

import java.time.Instant;
import java.util.List;

public final class ApprovalSettingsDto {

    private ApprovalSettingsDto() {
    }

    /**
     * Partial update: a null field leaves that knob unchanged. An EMPTY
     * riskyTypes list deliberately disables risky-type gating. Per-item
     * validation (charset/length/count) happens in the service.
     */
    public record UpdateRequest(
            @Min(1) @Max(500) Integer complexNodeThreshold,
            List<String> riskyTypes) {
    }

    /** riskyTypes is the tenant's EFFECTIVE set; platform defaults included for the UI. */
    public record Response(
            int complexNodeThreshold,
            int platformDefault,
            List<String> riskyTypes,
            List<String> platformRiskyTypes,
            boolean riskyTypesCustomized,
            String updatedBy,
            Instant updatedAt) {

        public static Response from(ApprovalSetting s) {
            return new Response(s.getComplexNodeThreshold(), WorkflowComplexity.NODE_THRESHOLD,
                    ApprovalSettingsService.effectiveRiskyTypes(s).stream().sorted().toList(),
                    WorkflowComplexity.RISKY_TYPES.stream().sorted().toList(),
                    s.getRiskyTypes() != null,
                    s.getUpdatedBy(), s.getUpdatedAt());
        }
    }
}
