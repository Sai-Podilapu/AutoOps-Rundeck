-- ============================================================
-- Bring-your-own-key model providers.
--
-- A tenant registers the AI vendors it already pays for (OpenAI, Anthropic,
-- Google, Azure, Bedrock, Huawei, Mistral, Groq, DeepSeek, xAI) or points at
-- a self-hosted OpenAI-compatible endpoint (Ollama). AutoOps stores the
-- credential AES-GCM encrypted and never returns it — the same treatment
-- cloud credentials and connector configs already get.
--
-- ONE ROW PER KIND PER TENANT (uk_model_providers_tenant_kind). That is what
-- makes model resolution unambiguous: a model id names a vendor, the vendor
-- names exactly one credential in this workspace. Registering a second key
-- for the same vendor is an UPDATE, not a second row.
--
-- config_enc holds a per-kind JSON shape, because these vendors do not agree
-- on what a credential is: {"apiKey":...} for the bearer-token vendors,
-- {"baseUrl":...} for Ollama (no secret at all), and multi-field objects for
-- Azure ({endpoint,deployment,apiKey}), Bedrock and Huawei ({accessKey,
-- secretKey,region,...}). Validating that shape is ModelProviderCatalog's
-- job, not the schema's.
-- ============================================================

CREATE TABLE model_providers (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id      VARCHAR(64)     NOT NULL,
    kind           ENUM('OPENAI','ANTHROPIC','GOOGLE','AZURE_OPENAI','BEDROCK',
                        'HUAWEI','MISTRAL','GROQ','DEEPSEEK','XAI','OLLAMA') NOT NULL,
    -- Operator-facing label. Defaults to the vendor's display name.
    name           VARCHAR(128)    NOT NULL,
    config_enc     TEXT            NULL,          -- AES-GCM, per-kind JSON
    -- Preferred model id for this vendor; agents may still name another.
    default_model  VARCHAR(128)    NULL,
    enabled        TINYINT(1)      NOT NULL DEFAULT 1,
    last_test_ok   TINYINT(1)      NULL,          -- null = never tested
    last_test_at   TIMESTAMP(6)    NULL,
    -- Why the last test failed, so the console can show a real reason.
    last_test_note VARCHAR(512)    NULL,
    -- Model ids the vendor reported on the last SUCCESSFUL test, as a JSON
    -- array. Cached so the agent builder's model picker opens instantly
    -- instead of fanning out to every configured vendor on each page load;
    -- refreshed on every successful test, and never the source of truth.
    models_json    TEXT            NULL,
    created_by     VARCHAR(255)    NULL,
    created_at     TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at     TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                       ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_model_providers_tenant_kind (tenant_id, kind),
    KEY idx_model_providers_tenant (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------
-- Audit ENUM: adds the four MODEL_PROVIDER_* events, and RESTORES the five
-- AGENT_* values.
--
-- V22 added AGENT_CREATED/UPDATED/DELETED/ENABLED/DISABLED. V24 then re-issued
-- MODIFY event_type with a list that omitted them, which silently dropped all
-- five — MySQL applies the new ENUM wholesale, it does not merge. agent-service
-- posts those events to core-service's /internal/audit, so every agent write
-- has been failing its audit insert since V24. Restored here because this
-- migration rewrites the same column; a MODIFY that left them out would
-- re-drop them a second time.
-- ------------------------------------------------------------

ALTER TABLE core_audit_log
    MODIFY event_type ENUM('PROJECT_CREATED','PROJECT_UPDATED','PROJECT_ARCHIVED','PROJECT_RESTORED',
                      'WORKFLOW_CREATED','WORKFLOW_UPDATED','WORKFLOW_DELETED',
                      'WORKFLOW_ENABLED','WORKFLOW_DISABLED',
                      'JOB_CREATED','JOB_UPDATED','JOB_DELETED',
                      'AGENT_CREATED','AGENT_UPDATED','AGENT_DELETED',
                      'AGENT_ENABLED','AGENT_DISABLED',
                      'RUN_TRIGGERED','RUN_CANCELED',
                      'APPROVAL_REQUESTED','APPROVAL_APPROVED','APPROVAL_REJECTED',
                      'CONNECTION_CREATED','CONNECTION_CREDENTIALS_UPDATED',
                      'CONNECTION_VERIFIED','CONNECTION_DISCONNECTED','CONNECTION_ASSIGNED',
                      'CONNECTION_CLAIM_REJECTED','CONNECTION_QUARANTINED',
                      'SCM_CONFIGURED','SCM_EXPORTED','SCM_IMPORTED',
                      'APPROVAL_SETTINGS_UPDATED','GOVERNANCE_POLICY_UPDATED',
                      'COMPLIANCE_REPORT_GENERATED',
                      'SECRET_CREATED','SECRET_UPDATED','SECRET_DELETED',
                      'WEBHOOK_CREATED','WEBHOOK_UPDATED','WEBHOOK_DELETED',
                      'COMMAND_DISPATCHED',
                      'CONNECTOR_CREATED','CONNECTOR_DELETED',
                      'LIBRARY_CREATED','LIBRARY_CLONED',
                      'BROADCAST_SENT',
                      'TEMPLATE_ROLLED_OUT','TEMPLATE_REVOKED',
                      'MODEL_PROVIDER_CREATED','MODEL_PROVIDER_UPDATED',
                      'MODEL_PROVIDER_DELETED','MODEL_PROVIDER_VERIFIED') NOT NULL;
