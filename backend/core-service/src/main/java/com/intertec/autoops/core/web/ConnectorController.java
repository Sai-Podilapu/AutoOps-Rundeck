package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.Connector;
import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.AuditService;
import com.intertec.autoops.core.service.ConnectorService;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** Third-party plugins; config never returned, tests are real calls. */
@RestController
@RequestMapping("/api/connectors")
public class ConnectorController {

    private final ConnectorService connectorService;
    private final AuditService auditService;

    public ConnectorController(ConnectorService connectorService, AuditService auditService) {
        this.connectorService = connectorService;
        this.auditService = auditService;
    }

    public record ConnectorRequest(@NotBlank @Size(max = 32) String kind,
                                   @NotBlank @Size(max = 128) String name,
                                   @NotBlank String config) {
    }

    public record ConnectorResponse(Long id, String kind, String name, Boolean lastTestOk,
                                    Instant lastTestAt, Instant createdAt) {

        static ConnectorResponse from(Connector connector) {
            return new ConnectorResponse(connector.getId(),
                    connector.getKind().name().toLowerCase(Locale.ROOT), connector.getName(),
                    connector.getLastTestOk(), connector.getLastTestAt(),
                    connector.getCreatedAt());
        }
    }

    @GetMapping
    public List<ConnectorResponse> list(@AuthenticationPrincipal Jwt jwt) {
        return connectorService.list(tenant(jwt)).stream()
                .map(ConnectorResponse::from).toList();
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public ConnectorResponse create(@Valid @RequestBody ConnectorRequest request,
                                    @AuthenticationPrincipal Jwt jwt) {
        Connector connector = connectorService.create(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), request.kind(), request.name(), request.config());
        auditService.record(CoreAuditEventType.CONNECTOR_CREATED, tenant(jwt),
                jwt.getSubject(), null, "CONNECTOR", connector.getId(),
                connector.getName(), connector.getKind().name());
        return ConnectorResponse.from(connector);
    }

    @PostMapping("/{id}/test")
    public Map<String, Object> test(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        ConnectorService.TestResult result =
                connectorService.test(tenant(jwt), jwt.getTokenValue(), id);
        return result.ok()
                ? Map.of("ok", true, "message", result.message())
                : Map.of("ok", false, "error", result.message());
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        connectorService.delete(tenant(jwt), jwt.getTokenValue(), id);
        auditService.record(CoreAuditEventType.CONNECTOR_DELETED, tenant(jwt),
                jwt.getSubject(), null, "CONNECTOR", id, null, null);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
