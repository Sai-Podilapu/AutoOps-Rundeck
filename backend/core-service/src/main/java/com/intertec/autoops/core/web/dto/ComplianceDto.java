package com.intertec.autoops.core.web.dto;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.domain.ComplianceReport;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.time.Instant;

public final class ComplianceDto {

    private ComplianceDto() {
    }

    public record GenerateRequest(@NotBlank @Size(max = 32) String framework) {
    }

    /** List row: summary only, the findings snapshot stays on the detail view. */
    public record ReportSummary(
            Long id,
            Long projectId,
            String framework,
            String frameworkLabel,
            String status,
            int score,
            int controlsTotal,
            int passed,
            int warnings,
            int failed,
            String generatedBy,
            Instant createdAt) {

        public static ReportSummary from(ComplianceReport r) {
            return new ReportSummary(r.getId(), r.getProjectId(), r.getFramework().name(),
                    r.getFramework().label(), r.getStatus().name(), r.getScore(),
                    r.getControlsTotal(), r.getPassed(), r.getWarnings(), r.getFailed(),
                    r.getGeneratedBy(), r.getCreatedAt());
        }
    }

    /** Detail: the summary plus the parsed findings snapshot. */
    public record ReportDetail(ReportSummary report, JsonNode content) {

        public static ReportDetail from(ComplianceReport r, ObjectMapper mapper) {
            JsonNode content;
            try {
                content = mapper.readTree(r.getContent());
            } catch (Exception ex) {
                content = mapper.createObjectNode();
            }
            return new ReportDetail(ReportSummary.from(r), content);
        }
    }
}