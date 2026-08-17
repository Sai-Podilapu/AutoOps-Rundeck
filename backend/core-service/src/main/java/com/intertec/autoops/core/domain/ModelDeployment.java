package com.intertec.autoops.core.domain;

// ModelPurpose is a value enum that happens to live beside its classifier in
// the service package. Imported rather than duplicated here: two enums with
// the same constants would drift, and the ENUM column would then disagree
// with what the classifier produces for a probed model.
import com.intertec.autoops.core.service.ModelPurpose;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

/**
 * A model the tenant DECLARED against one of its connections, for the vendors
 * where discovery cannot work.
 *
 * <p>Most vendors answer "list models" with something a probe can read, and
 * for those this table stays empty — the probed list is authoritative and
 * nobody should be typing model ids by hand. The exceptions are the vendors
 * whose models are things the tenant created and named: an Azure deployment,
 * a ModelArts deployment id, a SageMaker endpoint, a fine-tune. No list
 * endpoint can return those in a useful form, so the choice is between letting
 * an operator declare one and leaving an empty picker. This is that.
 *
 * <p>Declared models are ADDITIVE — they are merged with whatever the probe
 * found, never a replacement for it.
 *
 * <p>Holds no secret: authentication belongs to the {@link ModelProvider} this
 * points at, which is why deleting that connection deletes these with it.
 */
@Entity
@Table(name = "model_deployments")
public class ModelDeployment {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Column(name = "provider_id", nullable = false)
    private Long providerId;

    /** Exactly what gets sent to the vendor as the model. */
    @Column(name = "model_name", nullable = false, length = 190)
    private String modelName;

    /**
     * The published model underneath, where the two differ. An Azure
     * deployment called "gpt4o-prod" is a gpt-4o, and knowing that is what
     * lets anything downstream say something true about its family.
     */
    @Column(name = "base_model", length = 190)
    private String baseModel;

    /**
     * Declared rather than inferred. {@code ModelPurposeClassifier} reads a
     * vendor's own ids by naming convention, which cannot work on a name the
     * tenant invented — "gpt4o-prod" announces nothing.
     */
    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition =
            "ENUM('CHAT','EMBEDDING','RERANK','IMAGE','AUDIO','VIDEO')")
    private ModelPurpose purpose = ModelPurpose.CHAT;

    /** Azure pins an api-version per deployment. */
    @Column(name = "api_version", length = 64)
    private String apiVersion;

    /** For a gateway that puts one model on a different host entirely. */
    @Column(length = 512)
    private String endpoint;

    @Column(nullable = false)
    private boolean enabled = true;

    @Column(name = "created_by", length = 255)
    private String createdBy;

    /** Set in code (H2 tests have no DB default). */
    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt = Instant.now();

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt = Instant.now();

    public Long getId() {
        return id;
    }

    public String getTenantId() {
        return tenantId;
    }

    public void setTenantId(String tenantId) {
        this.tenantId = tenantId;
    }

    public Long getProviderId() {
        return providerId;
    }

    public void setProviderId(Long providerId) {
        this.providerId = providerId;
    }

    public String getModelName() {
        return modelName;
    }

    public void setModelName(String modelName) {
        this.modelName = modelName;
    }

    public String getBaseModel() {
        return baseModel;
    }

    public void setBaseModel(String baseModel) {
        this.baseModel = baseModel;
    }

    public ModelPurpose getPurpose() {
        return purpose;
    }

    public void setPurpose(ModelPurpose purpose) {
        this.purpose = purpose;
    }

    public String getApiVersion() {
        return apiVersion;
    }

    public void setApiVersion(String apiVersion) {
        this.apiVersion = apiVersion;
    }

    public String getEndpoint() {
        return endpoint;
    }

    public void setEndpoint(String endpoint) {
        this.endpoint = endpoint;
    }

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public String getCreatedBy() {
        return createdBy;
    }

    public void setCreatedBy(String createdBy) {
        this.createdBy = createdBy;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    public Instant getUpdatedAt() {
        return updatedAt;
    }

    public void setUpdatedAt(Instant updatedAt) {
        this.updatedAt = updatedAt;
    }
}
