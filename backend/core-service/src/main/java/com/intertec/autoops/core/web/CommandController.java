package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.CommandRecord;
import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.AuditService;
import com.intertec.autoops.core.service.CommandService;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.List;

/** Ad-hoc command dispatch on the platform runner + history. */
@RestController
@RequestMapping("/api/commands")
public class CommandController {

    private final CommandService commandService;
    private final AuditService auditService;

    public CommandController(CommandService commandService, AuditService auditService) {
        this.commandService = commandService;
        this.auditService = auditService;
    }

    public record DispatchRequest(@NotBlank @Size(max = 512) String command) {
    }

    public record CommandResponse(Long id, String command, String target, String dispatchedBy,
                                  String status, String output, Long durationMs,
                                  Instant createdAt) {

        static CommandResponse from(CommandRecord record) {
            return new CommandResponse(record.getId(), record.getCommand(), record.getTarget(),
                    record.getDispatchedBy(), record.getStatus().name(), record.getOutput(),
                    record.getDurationMs(), record.getCreatedAt());
        }
    }

    @GetMapping
    public List<CommandResponse> history(@AuthenticationPrincipal Jwt jwt) {
        return commandService.history(tenant(jwt)).stream()
                .map(CommandResponse::from).toList();
    }

    @PostMapping
    public CommandResponse dispatch(@Valid @RequestBody DispatchRequest request,
                                    @AuthenticationPrincipal Jwt jwt) {
        CommandRecord record = commandService.dispatch(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), request.command());
        auditService.record(CoreAuditEventType.COMMAND_DISPATCHED, tenant(jwt),
                jwt.getSubject(), null, "COMMAND", record.getId(), null,
                record.getCommand());
        return CommandResponse.from(record);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
