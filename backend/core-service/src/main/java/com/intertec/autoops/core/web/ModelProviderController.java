package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.domain.ModelDeployment;
import com.intertec.autoops.core.domain.ModelProvider;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.AuditService;
import com.intertec.autoops.core.service.ModelProviderCatalog;
import com.intertec.autoops.core.service.ModelProviderProbe;
import com.intertec.autoops.core.service.ModelProviderService;
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
 * Bring-your-own-key AI providers. Tenant always comes from the token claim,
 * and the stored credential is NEVER part of any response — the console gets
 * metadata and a test outcome, nothing else.
 */
@RestController
@RequestMapping("/api/model-providers")
public class ModelProviderController {

    private final ModelProviderService providerService;
    private final AuditService auditService;

    public ModelProviderController(ModelProviderService providerService,
                                   AuditService auditService) {
        this.providerService = providerService;
        this.auditService = auditService;
    }

    /**
     * {@code config} is write-only — it is accepted here and never echoed.
     *
     * @param id null to create a new connection; set to replace the credential
     *           on an existing one. A create whose name is taken is rejected
     *           rather than overwritten, so "add a second key for this vendor"
     *           can never be mistaken for "rotate the one I have".
     */
    public record ProviderRequest(Long id,
                                  @NotBlank @Size(max = 32) String kind,
                                  @Size(max = 128) String name,
                                  @Size(max = 32) String authMethod,
                                  @NotBlank @Size(max = 8192) String config,
                                  @Size(max = 128) String defaultModel,
                                  @Size(max = 128) String defaultEmbeddingModel,
                                  @Size(max = 128) String defaultRerankModel) {
    }

    /** Re-pointing a purpose at another model, without re-sending the key. */
    public record DefaultsRequest(@Size(max = 128) String defaultModel,
                                  @Size(max = 128) String defaultEmbeddingModel,
                                  @Size(max = 128) String defaultRerankModel) {
    }

    public record ProviderResponse(Long id, String kind, String displayName, String name,
                                   String authMethod, String defaultModel,
                                   String defaultEmbeddingModel, String defaultRerankModel,
                                   boolean enabled, Boolean lastTestOk,
                                   Instant lastTestAt, String lastTestNote,
                                   Instant modelsRefreshedAt, String createdBy,
                                   Instant createdAt, Instant updatedAt) {

        static ProviderResponse from(ModelProvider provider) {
            return new ProviderResponse(provider.getId(), provider.getKind().name(),
                    ModelProviderCatalog.spec(provider.getKind()).displayName(),
                    provider.getName(), provider.getAuthMethod(), provider.getDefaultModel(),
                    provider.getDefaultEmbeddingModel(), provider.getDefaultRerankModel(),
                    provider.isEnabled(), provider.getLastTestOk(), provider.getLastTestAt(),
                    provider.getLastTestNote(), provider.getModelsRefreshedAt(),
                    provider.getCreatedBy(), provider.getCreatedAt(), provider.getUpdatedAt());
        }
    }

    /**
     * A model the tenant DECLARED, for the vendors whose models are things
     * they created and named rather than anything a probe can discover.
     */
    public record DeploymentRequest(Long id,
                                    @NotBlank @Size(max = 190) String modelName,
                                    @Size(max = 190) String baseModel,
                                    @Size(max = 16) String purpose,
                                    @Size(max = 64) String apiVersion,
                                    @Size(max = 512) String endpoint) {
    }

    public record DeploymentResponse(Long id, Long providerId, String modelName,
                                     String baseModel, String purpose, String apiVersion,
                                     String endpoint, boolean enabled, Instant createdAt,
                                     Instant updatedAt) {

        static DeploymentResponse from(ModelDeployment deployment) {
            return new DeploymentResponse(deployment.getId(), deployment.getProviderId(),
                    deployment.getModelName(), deployment.getBaseModel(),
                    deployment.getPurpose().name(), deployment.getApiVersion(),
                    deployment.getEndpoint(), deployment.isEnabled(),
                    deployment.getCreatedAt(), deployment.getUpdatedAt());
        }
    }

    public record TestResponse(boolean ok, String message, List<String> models) {
    }

    /** Same credential shape as a save, minus everything about storing it. */
    public record VerifyRequest(@NotBlank @Size(max = 32) String kind,
                                @Size(max = 32) String authMethod,
                                @NotBlank @Size(max = 8192) String config,
                                @Size(max = 128) String defaultModel) {
    }

    public record RefreshResponse(int refreshed, int total) {
    }

    @GetMapping
    public List<ProviderResponse> list(@AuthenticationPrincipal Jwt jwt) {
        return providerService.list(tenant(jwt)).stream().map(ProviderResponse::from).toList();
    }

    /**
     * The vendors AutoOps can talk to and what each one needs. Static — it
     * describes the software, not the tenant — so the console can render the
     * "add provider" form without a round trip per vendor.
     */
    @GetMapping("/catalog")
    public List<ModelProviderCatalog.Spec> catalog() {
        return ModelProviderCatalog.all();
    }

    /** Models the workspace can actually reach, for the agent builder. */
    @GetMapping("/models")
    public List<ModelProviderService.AvailableModels> models(@AuthenticationPrincipal Jwt jwt) {
        return providerService.availableModels(tenant(jwt));
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public ProviderResponse save(@Valid @RequestBody ProviderRequest request,
                                 @AuthenticationPrincipal Jwt jwt) {
        // The id is what distinguishes the two, now that a vendor can hold
        // more than one connection — presence of a row for the same kind no
        // longer means this request is an update to it.
        boolean existed = request.id() != null;
        ModelProvider provider = providerService.save(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), request.id(), request.kind(), request.name(),
                request.authMethod(), request.config(), request.defaultModel(),
                request.defaultEmbeddingModel(), request.defaultRerankModel());
        audit(existed ? CoreAuditEventType.MODEL_PROVIDER_UPDATED
                : CoreAuditEventType.MODEL_PROVIDER_CREATED, jwt, provider, null);
        return ProviderResponse.from(provider);
    }

    /** Defaults only — no credential in, no credential out. */
    @PostMapping("/{id}/defaults")
    public ProviderResponse setDefaults(@PathVariable Long id,
                                        @Valid @RequestBody DefaultsRequest request,
                                        @AuthenticationPrincipal Jwt jwt) {
        ModelProvider provider = providerService.setDefaults(tenant(jwt), jwt.getTokenValue(),
                id, request.defaultModel(), request.defaultEmbeddingModel(),
                request.defaultRerankModel());
        audit(CoreAuditEventType.MODEL_PROVIDER_UPDATED, jwt, provider, "default models");
        return ProviderResponse.from(provider);
    }

    // ---- declared models -------------------------------------------------

    @GetMapping("/{id}/deployments")
    public List<DeploymentResponse> deployments(@PathVariable Long id,
                                                @AuthenticationPrincipal Jwt jwt) {
        return providerService.deployments(tenant(jwt), id).stream()
                .map(DeploymentResponse::from).toList();
    }

    @PostMapping("/{id}/deployments")
    @ResponseStatus(HttpStatus.CREATED)
    public DeploymentResponse saveDeployment(@PathVariable Long id,
                                             @Valid @RequestBody DeploymentRequest request,
                                             @AuthenticationPrincipal Jwt jwt) {
        ModelDeployment deployment = providerService.saveDeployment(tenant(jwt),
                jwt.getSubject(), jwt.getTokenValue(), id, request.id(), request.modelName(),
                request.baseModel(), request.purpose(), request.apiVersion(),
                request.endpoint());
        // Reuses MODEL_PROVIDER_UPDATED rather than growing the audit ENUM:
        // V24 showed that re-issuing that column's value list silently drops
        // anything omitted, and a declared model is a change to the provider.
        audit(CoreAuditEventType.MODEL_PROVIDER_UPDATED, jwt,
                providerService.get(tenant(jwt), id), "model " + deployment.getModelName());
        return DeploymentResponse.from(deployment);
    }

    @DeleteMapping("/{id}/deployments/{deploymentId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void deleteDeployment(@PathVariable Long id, @PathVariable Long deploymentId,
                                 @AuthenticationPrincipal Jwt jwt) {
        providerService.deleteDeployment(tenant(jwt), jwt.getTokenValue(), deploymentId);
        audit(CoreAuditEventType.MODEL_PROVIDER_UPDATED, jwt,
                providerService.get(tenant(jwt), id), "model removed");
    }

    // ---- refresh ---------------------------------------------------------

    /**
     * Re-reads the model lists from every enabled vendor. Same call as Test —
     * a vendor's list endpoint IS the credential check — so each connection's
     * outcome lands on its own row and the console reads it from there.
     */
    @PostMapping("/refresh")
    public RefreshResponse refreshAll(@AuthenticationPrincipal Jwt jwt) {
        List<ModelProvider> providers = providerService.list(tenant(jwt));
        int total = (int) providers.stream().filter(ModelProvider::isEnabled).count();
        return new RefreshResponse(
                providerService.refreshAll(tenant(jwt), jwt.getTokenValue()), total);
    }

    @PostMapping("/{id}/refresh")
    public TestResponse refresh(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        ModelProviderProbe.ProbeResult result =
                providerService.refresh(tenant(jwt), jwt.getTokenValue(), id);
        return new TestResponse(result.ok(), result.message(), result.models());
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        providerService.delete(tenant(jwt), jwt.getTokenValue(), id);
        auditService.record(CoreAuditEventType.MODEL_PROVIDER_DELETED, tenant(jwt),
                jwt.getSubject(), null, "MODEL_PROVIDER", id, null, null);
    }

    /**
     * Preflight, the twin of {@code POST /cloud/connections/verify}: check a
     * credential with the vendor BEFORE it is stored, so a rejected key never
     * becomes a saved connection that merely looks configured.
     *
     * <p>Writes nothing — no row, no audit event. There is no subject to
     * audit yet, and a failed attempt to type a key is not a security event.
     * The durable record is still {@code POST /{id}/test} after the save.
     */
    @PostMapping("/verify")
    public TestResponse verify(@Valid @RequestBody VerifyRequest request,
                               @AuthenticationPrincipal Jwt jwt) {
        ModelProviderProbe.ProbeResult result = providerService.verify(jwt.getTokenValue(),
                request.kind(), request.authMethod(), request.config(),
                request.defaultModel());
        return new TestResponse(result.ok(), result.message(), result.models());
    }

    @PostMapping("/{id}/test")
    public TestResponse test(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        ModelProviderProbe.ProbeResult result =
                providerService.test(tenant(jwt), jwt.getTokenValue(), id);
        if (result.ok()) {
            audit(CoreAuditEventType.MODEL_PROVIDER_VERIFIED, jwt,
                    providerService.get(tenant(jwt), id), result.message());
        }
        return new TestResponse(result.ok(), result.message(), result.models());
    }

    @PostMapping("/{id}/enabled")
    public ProviderResponse setEnabled(@PathVariable Long id,
                                       @RequestBody EnabledRequest request,
                                       @AuthenticationPrincipal Jwt jwt) {
        ModelProvider provider = providerService.setEnabled(tenant(jwt), jwt.getTokenValue(),
                id, request.enabled());
        audit(CoreAuditEventType.MODEL_PROVIDER_UPDATED, jwt, provider,
                request.enabled() ? "enabled" : "disabled");
        return ProviderResponse.from(provider);
    }

    public record EnabledRequest(boolean enabled) {
    }

    /** Vendor and label only — never any part of the credential. */
    private void audit(CoreAuditEventType type, Jwt jwt, ModelProvider provider, String details) {
        auditService.record(type, tenant(jwt), jwt.getSubject(), null, "MODEL_PROVIDER",
                provider.getId(), provider.getKind().name(), details);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
