-- ============================================================
-- rundeck-service owns the CONNECTION to a tenant's own Rundeck server.
--
-- It deliberately owns nothing else. Jobs, executions, nodes and logs stay in
-- Rundeck and are read through its API on demand — mirroring them here would
-- create a second copy of the truth that goes stale the moment someone edits a
-- job in the Rundeck console, which they will.
--
-- The API token is the whole security story of this table: a Rundeck token is
-- command execution across a customer's fleet. It is AES-256-GCM sealed with
-- RUNDECK_CRED_KEY (its own key, NOT CLOUD_CRED_KEY) and never leaves this
-- service in plaintext — no endpoint returns it, and `token_hint` exists so the
-- console can show which token is configured without ever holding one.
-- ============================================================

CREATE TABLE rundeck_connections (
    id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id         VARCHAR(64)     NOT NULL,
    name              VARCHAR(128)    NOT NULL,
    base_url          VARCHAR(512)    NOT NULL,   -- https://rundeck.example.com
    api_version       INT UNSIGNED    NOT NULL DEFAULT 41,
    -- base64(iv[12] || ciphertext+tag). Never selected into any response DTO.
    api_token_enc     TEXT            NOT NULL,
    -- Last 4 characters of the token, in clear, so the UI can say WHICH token
    -- is stored. Four characters of a 20+ char Rundeck token is not a secret.
    token_hint        VARCHAR(8)      NULL,
    -- Optional default project, so the console can open straight into it.
    default_project   VARCHAR(255)    NULL,

    -- Verification is a live call to Rundeck's /system/info, never a guess.
    status            ENUM('UNVERIFIED','VERIFIED','FAILED')
                                      NOT NULL DEFAULT 'UNVERIFIED',
    server_version    VARCHAR(64)     NULL,       -- reported by /system/info
    server_name       VARCHAR(255)    NULL,
    last_error        VARCHAR(512)    NULL,       -- why the last check failed
    last_verified_at  TIMESTAMP(6)    NULL,

    enabled           TINYINT(1)      NOT NULL DEFAULT 1,
    created_by        VARCHAR(255)    NULL,
    created_at        TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at        TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                      ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- One name per workspace: the console addresses connections by name in
    -- step definitions, so two "prod" rows would make a step ambiguous.
    UNIQUE KEY uq_rundeck_tenant_name (tenant_id, name),
    KEY idx_rundeck_tenant (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;


-- Dispatches AutoOps initiated. Rundeck keeps the execution and its log; this
-- is the AutoOps-side receipt, so a run that was triggered from here can still
-- be attributed after the token is rotated or the connection is deleted.
--
-- It is an append-only trail, not a mirror: `status` is a snapshot at the last
-- poll, and the execution page always re-reads Rundeck for the live answer.
CREATE TABLE rundeck_dispatches (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id      VARCHAR(64)     NOT NULL,
    connection_id  BIGINT UNSIGNED NOT NULL,
    rundeck_project VARCHAR(255)   NULL,
    job_id         VARCHAR(64)     NOT NULL,      -- Rundeck job UUID
    job_name       VARCHAR(255)    NULL,          -- snapshotted: jobs get renamed
    execution_id   BIGINT UNSIGNED NULL,          -- Rundeck's execution id
    node_filter    VARCHAR(512)    NULL,
    -- Option values as submitted. Rundeck secure options are NEVER sent here
    -- by the console and are stripped server-side before this is written.
    options_json   TEXT            NULL,
    status         VARCHAR(32)     NOT NULL DEFAULT 'SUBMITTED',
    triggered_by   VARCHAR(255)    NULL,
    error          VARCHAR(512)    NULL,
    created_at     TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at     TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                   ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_dispatch_tenant (tenant_id),
    KEY idx_dispatch_connection (connection_id),
    KEY idx_dispatch_execution (connection_id, execution_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
