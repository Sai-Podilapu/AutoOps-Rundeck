-- ============================================================
-- plugin-service owns notification CHANNELS and the rules that fire them.
--
-- Three tables, every one of them carrying tenant_id NOT NULL. This service
-- has no ambient tenant: delivery happens on a worker thread, long after the
-- request that caused it has gone, so the tenant has to live on the row. Every
-- repository finder pairs an id with a tenant_id for the same reason
-- core-service does it — by id alone, one workspace could read, test or delete
-- another's Slack webhook.
--
-- This service supersedes core-service's `connectors` table (V16), which had
-- SLACK_WEBHOOK / GENERIC_WEBHOOK / GITHUB as a MySQL ENUM and no dispatcher
-- attached. Nothing here reads that table; migrating rows across is a separate
-- step, and the old one stays untouched until it is done.
-- ============================================================

-- ------------------------------------------------------------
-- A tenant's configured copy of one plugin.
-- ------------------------------------------------------------
CREATE TABLE plugin_installations (
    id                    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id             VARCHAR(64)     NOT NULL,
    -- Matches PluginDescriptor#key(). VARCHAR, NOT an ENUM: the old
    -- connectors table pinned its three kinds into the DDL, so adding a
    -- provider meant an ALTER TABLE. Adding one here is a new package.
    plugin_key            VARCHAR(64)     NOT NULL,
    display_name          VARCHAR(128)    NOT NULL,
    -- The whole config map as AES-256-GCM ciphertext, base64(iv||ct+tag).
    -- Encrypted with PLUGIN_CRED_KEY, which is deliberately NOT
    -- core-service's CLOUD_CRED_KEY.
    config_enc            TEXT            NOT NULL,
    enabled               TINYINT(1)      NOT NULL DEFAULT 1,
    -- PARKED is set by the dispatcher after repeated permanent failures, so a
    -- revoked webhook stops being retried on every single run.
    status                ENUM('ACTIVE','PARKED') NOT NULL DEFAULT 'ACTIVE',
    last_test_ok          TINYINT(1)      NULL,
    last_test_at          TIMESTAMP(6)    NULL,
    last_test_detail      VARCHAR(1024)   NULL,
    consecutive_failures  INT UNSIGNED    NOT NULL DEFAULT 0,
    created_by            VARCHAR(255)    NULL,
    created_at            TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at            TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                          ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- Scoped to the tenant, not global: two workspaces may both name a
    -- channel "Ops alerts", and a global unique key would leak the existence
    -- of one tenant's channel to another as a 409.
    UNIQUE KEY uq_installations_tenant_name (tenant_id, display_name),
    KEY idx_installations_tenant (tenant_id),
    KEY idx_installations_tenant_plugin (tenant_id, plugin_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------
-- "Send me {events} for {target} through {installation}."
-- ------------------------------------------------------------
CREATE TABLE notification_rules (
    id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id        VARCHAR(64)     NOT NULL,
    installation_id  BIGINT UNSIGNED NOT NULL,
    target_type      ENUM('JOB','WORKFLOW') NOT NULL,
    -- NULL widens the rule: target_id NULL = every target of this type,
    -- project_id NULL = every project. Both NULL = the whole workspace.
    -- Wildcards are the point — a per-job rule never covers the job someone
    -- adds next week.
    target_id        BIGINT UNSIGNED NULL,
    project_id       BIGINT UNSIGNED NULL,
    -- Comma-separated LifecycleEvent names, stored in enum order.
    events           VARCHAR(255)    NOT NULL,
    enabled          TINYINT(1)      NOT NULL DEFAULT 1,
    created_by       VARCHAR(255)    NULL,
    created_at       TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at       TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                     ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- Deleting a channel takes its rules with it; a rule pointing at a gone
    -- installation would fail on every event forever.
    CONSTRAINT fk_rules_installation FOREIGN KEY (installation_id)
        REFERENCES plugin_installations (id) ON DELETE CASCADE,
    -- The dispatch hot path: tenant + type, then wildcard matching in Java.
    KEY idx_rules_dispatch (tenant_id, target_type, enabled),
    KEY idx_rules_installation (installation_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------
-- One row per attempt. Successes too, not just failures.
--
-- The precedent is SendGrid: a send to a suppressed address returns 202 and
-- is dropped silently, leaving nothing behind. "They say they never got the
-- alert" has to be answerable, and only a row like this answers it.
-- ------------------------------------------------------------
CREATE TABLE delivery_attempts (
    id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id        VARCHAR(64)     NOT NULL,
    installation_id  BIGINT UNSIGNED NOT NULL,
    -- Denormalised so the log outlives the installation it refers to.
    plugin_key       VARCHAR(64)     NOT NULL,
    rule_id          BIGINT UNSIGNED NULL,   -- NULL for a manual test
    target_type      ENUM('JOB','WORKFLOW') NULL,
    target_id        BIGINT UNSIGNED NULL,
    target_name      VARCHAR(255)    NULL,
    event            VARCHAR(32)     NOT NULL,
    run_id           BIGINT UNSIGNED NULL,
    ok               TINYINT(1)      NOT NULL,
    status_code      INT             NULL,   -- 0 for SMTP, which has none
    detail           VARCHAR(1024)   NULL,   -- truncated; never a credential
    attempted_at     TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- No FK to plugin_installations on purpose: the audit trail must survive
    -- the channel being deleted, which is exactly when someone asks what
    -- happened.
    KEY idx_attempts_tenant_time (tenant_id, attempted_at),
    KEY idx_attempts_installation (installation_id, attempted_at),
    -- Retention trim scans by age across all tenants.
    KEY idx_attempts_time (attempted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
