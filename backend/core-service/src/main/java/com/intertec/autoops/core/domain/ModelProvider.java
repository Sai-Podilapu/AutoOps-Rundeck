package com.intertec.autoops.core.domain;

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
 * A tenant's own credential for an AI model vendor — bring-your-own-key.
 * {@code configEnc} is AES-GCM encrypted and NEVER serialised to a client;
 * "test" performs a REAL call against the vendor and records the outcome, so
 * a provider that has never been proven shows exactly that.
 *
 * <p>A tenant may hold SEVERAL connections to the same vendor — production and
 * sandbox Azure resources, one OpenAI key per cost centre — so the unique key
 * is (tenant, kind, {@code name}). That makes {@code name} load-bearing rather
 * than decorative: it is what an operator picks between, and what a second
 * connection must differ by.
 */
@Entity
@Table(name = "model_providers")
public class ModelProvider {

    /**
     * The vendors AutoOps can talk to. Adding one = a constant here, the
     * ENUM in a migration, and an entry in {@code ModelProviderCatalog}
     * (which owns the credential shape and the validation call).
     */
    public enum Kind {
        OPENAI,
        ANTHROPIC,
        GOOGLE,
        AZURE_OPENAI,
        BEDROCK,
        HUAWEI,
        MISTRAL,
        GROQ,
        DEEPSEEK,
        XAI,
        /** Self-hosted OpenAI-compatible endpoint — a URL, not a secret. */
        OLLAMA,
        /** Speech only: text-to-speech and transcription, nothing to chat with. */
        ELEVENLABS,
        /** The tenant's own deployed endpoints, not a published model list. */
        SAGEMAKER,
        OPENROUTER,
        HUGGINGFACE
    }

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "tenant_id", nullable = false, length = 64)
    private String tenantId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, columnDefinition =
            "ENUM('OPENAI','ANTHROPIC','GOOGLE','AZURE_OPENAI','BEDROCK',"
                    + "'HUAWEI','MISTRAL','GROQ','DEEPSEEK','XAI','OLLAMA',"
                    + "'ELEVENLABS','SAGEMAKER','OPENROUTER','HUGGINGFACE')")
    private Kind kind;

    @Column(nullable = false, length = 128)
    private String name;

    /**
     * Which credential shape {@code configEnc} holds, for the vendors that
     * accept more than one — Azure takes an API key OR an Entra ID service
     * principal. Null means the vendor's default method, which is also every
     * row saved before there was a choice.
     */
    @Column(name = "auth_method", length = 32)
    private String authMethod;

    @Column(name = "config_enc", columnDefinition = "TEXT")
    private String configEnc;

    @Column(name = "default_model", length = 128)
    private String defaultModel;

    /** Retrieval, not conversation — a different model family entirely. */
    @Column(name = "default_embedding_model", length = 128)
    private String defaultEmbeddingModel;

    /** Scores retrieved passages; a third family again, not an embedder. */
    @Column(name = "default_rerank_model", length = 128)
    private String defaultRerankModel;

    @Column(nullable = false)
    private boolean enabled = true;

    @Column(name = "last_test_ok")
    private Boolean lastTestOk;

    @Column(name = "last_test_at")
    private Instant lastTestAt;

    @Column(name = "last_test_note", length = 512)
    private String lastTestNote;

    /** JSON array of model ids from the last successful test; a cache. */
    @Column(name = "models_json", columnDefinition = "TEXT")
    private String modelsJson;

    /**
     * When {@code modelsJson} was last refreshed from the vendor. Separate
     * from {@code lastTestAt} because a refresh can run long after the test
     * that first proved the key — and a picker should be able to admit that
     * its list is four weeks old rather than presenting it as current.
     */
    @Column(name = "models_refreshed_at")
    private Instant modelsRefreshedAt;

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

    public Kind getKind() {
        return kind;
    }

    public void setKind(Kind kind) {
        this.kind = kind;
    }

    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    public String getConfigEnc() {
        return configEnc;
    }

    public void setConfigEnc(String configEnc) {
        this.configEnc = configEnc;
    }

    public String getDefaultModel() {
        return defaultModel;
    }

    public void setDefaultModel(String defaultModel) {
        this.defaultModel = defaultModel;
    }

    public String getDefaultEmbeddingModel() {
        return defaultEmbeddingModel;
    }

    public void setDefaultEmbeddingModel(String defaultEmbeddingModel) {
        this.defaultEmbeddingModel = defaultEmbeddingModel;
    }

    public String getDefaultRerankModel() {
        return defaultRerankModel;
    }

    public void setDefaultRerankModel(String defaultRerankModel) {
        this.defaultRerankModel = defaultRerankModel;
    }

    public String getAuthMethod() {
        return authMethod;
    }

    public void setAuthMethod(String authMethod) {
        this.authMethod = authMethod;
    }

    public Instant getModelsRefreshedAt() {
        return modelsRefreshedAt;
    }

    public void setModelsRefreshedAt(Instant modelsRefreshedAt) {
        this.modelsRefreshedAt = modelsRefreshedAt;
    }

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public Boolean getLastTestOk() {
        return lastTestOk;
    }

    public void setLastTestOk(Boolean lastTestOk) {
        this.lastTestOk = lastTestOk;
    }

    public Instant getLastTestAt() {
        return lastTestAt;
    }

    public void setLastTestAt(Instant lastTestAt) {
        this.lastTestAt = lastTestAt;
    }

    public String getLastTestNote() {
        return lastTestNote;
    }

    public void setLastTestNote(String lastTestNote) {
        this.lastTestNote = lastTestNote;
    }

    public String getModelsJson() {
        return modelsJson;
    }

    public void setModelsJson(String modelsJson) {
        this.modelsJson = modelsJson;
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
