package com.intertec.autoops.core.web.dto;

import com.intertec.autoops.core.domain.ScmConfig;
import com.intertec.autoops.core.service.ScmService;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.time.Instant;
import java.util.List;

public final class ScmDto {

    private ScmDto() {
    }

    /**
     * token omitted/blank on update = keep the stored one; {@code clearToken}
     * is the explicit way to drop it (for a repo that needs no credentials),
     * and may not be combined with a new token.
     */
    public record ConfigRequest(
            @NotBlank @Size(max = 512) String repoUrl,
            @Size(max = 128) String branch,
            @Size(max = 256) String basePath,
            @Size(max = 128) String username,
            @Size(max = 512) String token,
            boolean clearToken) {
    }

    /** The token itself is never returned — only whether one is stored. */
    public record ConfigResponse(
            boolean configured,
            String repoUrl,
            String branch,
            String basePath,
            String username,
            boolean hasToken,
            String updatedBy,
            Instant updatedAt) {

        public static ConfigResponse from(ScmConfig c) {
            return new ConfigResponse(true, c.getRepoUrl(), c.getBranch(), c.getBasePath(),
                    c.getUsername(), c.getTokenEnc() != null, c.getUpdatedBy(), c.getUpdatedAt());
        }

        public static ConfigResponse unconfigured() {
            return new ConfigResponse(false, null, "main", "", null, false, null, null);
        }
    }

    public record ImportRequest(String strategy) {

        public ScmService.ImportStrategy toStrategy() {
            return "SKIP".equalsIgnoreCase(strategy)
                    ? ScmService.ImportStrategy.SKIP
                    : ScmService.ImportStrategy.OVERWRITE;
        }
    }

    public record ExportResponse(int jobs, int workflows, boolean pushed, String commitId) {
        public static ExportResponse from(ScmService.ExportResult r) {
            return new ExportResponse(r.jobs(), r.workflows(), r.pushed(), r.commitId());
        }
    }

    public record ImportResponse(int created, int updated, int skipped, List<String> errors) {
        public static ImportResponse from(ScmService.ImportResult r) {
            return new ImportResponse(r.created(), r.updated(), r.skipped(), r.errors());
        }
    }
}
