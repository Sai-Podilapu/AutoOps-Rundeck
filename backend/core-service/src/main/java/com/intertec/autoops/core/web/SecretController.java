package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.domain.Secret;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.AuditService;
import com.intertec.autoops.core.service.SecretService;
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
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.List;

/** Vault metadata + write-only values. Tenant always from the token claim. */
@RestController
@RequestMapping("/api/secrets")
public class SecretController {

    private final SecretService secretService;
    private final AuditService auditService;

    public SecretController(SecretService secretService, AuditService auditService) {
        this.secretService = secretService;
        this.auditService = auditService;
    }

    public record SecretRequest(@NotBlank @Size(max = 255) String path,
                                @Size(max = 16) String type,
                                @Size(max = 65535) String value) {
    }

    /** The value is NEVER part of any response. */
    public record SecretResponse(Long id, String path, String type, String createdBy,
                                 Instant createdAt, Instant updatedAt) {

        static SecretResponse from(Secret secret) {
            return new SecretResponse(secret.getId(), secret.getPath(),
                    secret.getType().name(), secret.getCreatedBy(),
                    secret.getCreatedAt(), secret.getUpdatedAt());
        }
    }

    @GetMapping
    public List<SecretResponse> list(@AuthenticationPrincipal Jwt jwt) {
        return secretService.list(tenant(jwt)).stream().map(SecretResponse::from).toList();
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public SecretResponse create(@Valid @RequestBody SecretRequest request,
                                 @AuthenticationPrincipal Jwt jwt) {
        Secret secret = secretService.create(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), request.path(),
                request.type() == null ? "OPAQUE" : request.type(), request.value());
        audit(CoreAuditEventType.SECRET_CREATED, jwt, secret);
        return SecretResponse.from(secret);
    }

    @PutMapping("/{id}")
    public SecretResponse update(@PathVariable Long id,
                                 @RequestBody SecretRequest request,
                                 @AuthenticationPrincipal Jwt jwt) {
        Secret secret = secretService.update(tenant(jwt), jwt.getTokenValue(), id,
                request.path(), request.type(), request.value());
        audit(CoreAuditEventType.SECRET_UPDATED, jwt, secret);
        return SecretResponse.from(secret);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        secretService.delete(tenant(jwt), jwt.getTokenValue(), id);
        auditService.record(CoreAuditEventType.SECRET_DELETED, tenant(jwt), jwt.getSubject(),
                null, "SECRET", id, null, null);
    }

    private void audit(CoreAuditEventType type, Jwt jwt, Secret secret) {
        // Path only — never the value, not even truncated.
        auditService.record(type, tenant(jwt), jwt.getSubject(), null, "SECRET",
                secret.getId(), secret.getPath(), null);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
