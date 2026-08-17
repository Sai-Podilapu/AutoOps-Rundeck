package com.intertec.autoops.auth.web;

import com.intertec.autoops.auth.domain.ApiKey;
import com.intertec.autoops.auth.service.ApiKeyService;
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

/**
 * API key management (bearer-authenticated) + the public key→token exchange.
 * The raw key appears in exactly one response: the creation call.
 */
@RestController
@RequestMapping("/api/auth")
public class ApiKeyController {

    private final ApiKeyService apiKeyService;

    public ApiKeyController(ApiKeyService apiKeyService) {
        this.apiKeyService = apiKeyService;
    }

    public record CreateKeyRequest(@NotBlank @Size(max = 128) String name) {
    }

    public record ApiKeyResponse(Long id, String name, String prefix, Instant createdAt,
                                 Instant lastUsedAt, String key) {

        static ApiKeyResponse from(ApiKey key, String rawKey) {
            return new ApiKeyResponse(key.getId(), key.getName(), key.getPrefix(),
                    key.getCreatedAt(), key.getLastUsedAt(), rawKey);
        }
    }

    @GetMapping("/api-keys")
    public List<ApiKeyResponse> list(@AuthenticationPrincipal Jwt jwt) {
        return apiKeyService.list(jwt.getClaimAsString("tenantId")).stream()
                .map(k -> ApiKeyResponse.from(k, null)).toList();
    }

    @PostMapping("/api-keys")
    @ResponseStatus(HttpStatus.CREATED)
    public ApiKeyResponse create(@Valid @RequestBody CreateKeyRequest request,
                                 @AuthenticationPrincipal Jwt jwt) {
        ApiKeyService.CreatedKey created = apiKeyService.create(
                jwt.getClaimAsString("tenantId"),
                ((Number) jwt.getClaim("userId")).longValue(),
                jwt.getTokenValue(), request.name());
        // The one and only time the raw key is ever returned.
        return ApiKeyResponse.from(created.record(), created.rawKey());
    }

    @DeleteMapping("/api-keys/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void revoke(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        apiKeyService.revoke(jwt.getClaimAsString("tenantId"),
                ((Number) jwt.getClaim("userId")).longValue(), id);
    }

    public record ExchangeRequest(@NotBlank String key) {
    }

    /** PUBLIC: machine callers trade their key for a short-lived token. */
    @PostMapping("/token/api-key")
    public ApiKeyService.ExchangeResult exchange(@Valid @RequestBody ExchangeRequest request) {
        return apiKeyService.exchange(request.key());
    }
}
