-- ============================================================
-- Model providers, part two: NAMED CONNECTIONS and DECLARED MODELS.
--
-- V25 allowed exactly one row per (tenant, kind) on the reasoning that "a
-- model id names a vendor, and the vendor names exactly one credential". That
-- holds right up until a tenant has two of the same vendor — a production and
-- a sandbox Azure resource, two Huawei projects, one OpenAI key per cost
-- centre — at which point the rule forces them to choose. It is replaced here
-- by (tenant, kind, name): several connections per vendor, each with its own
-- credential, its own test outcome and its own model list. `name` stops being
-- decoration and becomes the thing an operator picks between, so it is now
-- part of the key.
--
-- Nothing is lost in the move: every existing row already has a distinct
-- (tenant, kind) and therefore a distinct (tenant, kind, name).
--
-- model_deployments is the second half. Several vendors do not publish a model
-- list that a probe can read, because the "models" are things the TENANT
-- created and named: an Azure deployment, a ModelArts deployment id, a
-- SageMaker endpoint, an OpenAI fine-tune. For those, discovery cannot work
-- and the honest answer is to let the operator declare the model — with the
-- base model and API version it actually needs — rather than leave an empty
-- picker or invent entries. Declared models are ADDITIVE: the probed list is
-- still authoritative for vendors that publish one.
-- ============================================================

ALTER TABLE model_providers
    -- Which credential shape config_enc holds, when the vendor accepts more
    -- than one. NULL = the vendor's default (and every pre-existing row, all
    -- of which were saved before there was a choice).
    ADD COLUMN auth_method          VARCHAR(32)  NULL AFTER kind,
    -- Retrieval reranking. A third model family beside chat and embedding,
    -- and picking one is not optional for anyone doing RAG properly.
    ADD COLUMN default_rerank_model VARCHAR(128) NULL AFTER default_embedding_model,
    -- When models_json was last refreshed from the vendor. Distinct from
    -- last_test_at: a refresh may run on a schedule long after the test that
    -- first proved the key, and "this list is four weeks old" is exactly the
    -- thing a stale picker should be able to admit to.
    ADD COLUMN models_refreshed_at  TIMESTAMP(6) NULL AFTER models_json;

ALTER TABLE model_providers
    DROP INDEX uk_model_providers_tenant_kind,
    ADD UNIQUE KEY uk_model_providers_tenant_kind_name (tenant_id, kind, name);

CREATE TABLE model_deployments (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id     VARCHAR(64)     NOT NULL,
    provider_id   BIGINT UNSIGNED NOT NULL,
    -- What gets sent to the vendor as the model: an Azure deployment name, a
    -- ModelArts deployment id, a SageMaker endpoint name, a fine-tune id.
    model_name    VARCHAR(190)    NOT NULL,
    -- The published model underneath it, where that differs. Azure's
    -- "gpt4o-prod" deployment is a gpt-4o; knowing that is what lets a picker
    -- say anything true about the model's family.
    base_model    VARCHAR(190)    NULL,
    -- Declared, not guessed. ModelPurposeClassifier reads a vendor's ids by
    -- naming convention, which cannot work on a name the tenant invented.
    purpose       ENUM('CHAT','EMBEDDING','RERANK','IMAGE','AUDIO','VIDEO')
                      NOT NULL DEFAULT 'CHAT',
    -- Per-model overrides. Azure pins an api-version per deployment, and a
    -- self-hosted gateway may put one model on a different host entirely.
    api_version   VARCHAR(64)     NULL,
    endpoint      VARCHAR(512)    NULL,
    enabled       TINYINT(1)      NOT NULL DEFAULT 1,
    created_by    VARCHAR(255)    NULL,
    created_at    TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at    TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                      ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- One declaration per model per connection; re-declaring is an update.
    UNIQUE KEY uk_model_deployments_provider_model (provider_id, model_name),
    KEY idx_model_deployments_tenant (tenant_id),
    -- Deleting the credential deletes what was declared against it: a
    -- deployment with no way to authenticate is not a model anyone can call.
    CONSTRAINT fk_model_deployments_provider FOREIGN KEY (provider_id)
        REFERENCES model_providers (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
