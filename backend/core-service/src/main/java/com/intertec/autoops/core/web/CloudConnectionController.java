package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.CloudConnectionService;
import com.intertec.autoops.core.web.dto.CloudConnectionRequest;
import com.intertec.autoops.core.web.dto.CloudConnectionResponse;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/** Tenant-scoped cloud integrations. Tenant always from the token claim. */
@RestController
@RequestMapping("/api/cloud/connections")
public class CloudConnectionController {

    private final CloudConnectionService connectionService;
    private final com.intertec.autoops.core.service.AuditService auditService;

    public CloudConnectionController(CloudConnectionService connectionService,
                                     com.intertec.autoops.core.service.AuditService auditService) {
        this.connectionService = connectionService;
        this.auditService = auditService;
    }

    @GetMapping
    public List<CloudConnectionResponse> list(@AuthenticationPrincipal Jwt jwt) {
        return connectionService.list(tenant(jwt)).stream().map(this::describe).toList();
    }

    /** Response enriched with the connection's non-secret account identity. */
    private CloudConnectionResponse describe(
            com.intertec.autoops.core.domain.CloudConnection connection) {
        return CloudConnectionResponse.from(connection, connectionService.describe(connection));
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public CloudConnectionResponse connect(@Valid @RequestBody CloudConnectionRequest request,
                                           @AuthenticationPrincipal Jwt jwt) {
        var connection = connectionService.connect(tenant(jwt),
                jwt.getSubject(), jwt.getTokenValue(), request.platform(), request.name(),
                request.credentials(), request.projectId());
        audit(CoreAuditEventType.CONNECTION_CREATED, jwt, connection.getId(),
                connection.getName(), connection.getPlatform().name());
        return describe(connection);
    }

    /** Set/replace credentials on an existing connection (never returned). */
    @PutMapping("/{id}/credentials")
    public CloudConnectionResponse setCredentials(@PathVariable Long id,
                                                  @RequestBody CloudConnectionRequest request,
                                                  @AuthenticationPrincipal Jwt jwt) {
        var connection = connectionService.setCredentials(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), id, request.credentials());
        audit(CoreAuditEventType.CONNECTION_CREDENTIALS_UPDATED, jwt, connection.getId(),
                connection.getName(), connection.getPlatform().name());
        return describe(connection);
    }

    /** Assignment body: {projectId} — a tenant project id, or null = global. */
    public record ProjectAssignmentRequest(Long projectId) {
    }

    /** Assign the connection to one project, or back to global (null). */
    @PutMapping("/{id}/project")
    public CloudConnectionResponse assignProject(@PathVariable Long id,
                                                 @RequestBody ProjectAssignmentRequest request,
                                                 @AuthenticationPrincipal Jwt jwt) {
        var connection = connectionService.assignProject(tenant(jwt),
                jwt.getTokenValue(), id, request.projectId());
        audit(CoreAuditEventType.CONNECTION_ASSIGNED, jwt, connection.getId(),
                connection.getName(), connection.getProjectId() == null
                        ? "global" : "project " + connection.getProjectId());
        return describe(connection);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void disconnect(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        connectionService.disconnect(tenant(jwt), jwt.getTokenValue(), id);
        audit(CoreAuditEventType.CONNECTION_DISCONNECTED, jwt, id, null, null);
    }

    /**
     * Preflight: check credentials against the provider BEFORE creating the
     * connection, so nothing is stored until the user confirms. Not audited —
     * no state changes.
     */
    public record CredentialCheckRequest(String platform, String credentials) {
    }

    @PostMapping("/verify")
    public CloudConnectionService.VerificationOutcome verifyCredentials(
            @RequestBody CredentialCheckRequest request,
            @AuthenticationPrincipal Jwt jwt) {
        return connectionService.verifyCredentials(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), request.platform(), request.credentials());
    }

    /** Live check of the stored credentials against the real provider. */
    @PostMapping("/{id}/verify")
    public CloudConnectionService.VerificationOutcome verify(@PathVariable Long id,
                                                             @AuthenticationPrincipal Jwt jwt) {
        var outcome = connectionService.verify(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), id);
        audit(CoreAuditEventType.CONNECTION_VERIFIED, jwt, id, null,
                (outcome.verified() ? "ok: " : "failed: ") + outcome.message());
        return outcome;
    }

    private void audit(CoreAuditEventType type, Jwt jwt, Long connectionId, String name,
                       String detail) {
        auditService.record(type, tenant(jwt), jwt.getSubject(), null, "CONNECTION",
                connectionId, name, detail);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
