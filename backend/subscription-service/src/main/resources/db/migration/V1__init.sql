-- ============================================================
-- AutoOps subscription-service — MySQL schema (database: autoops_subscription)
-- Managed by Flyway. spring.jpa.hibernate.ddl-auto = validate
-- TYPE POLICY: closed value sets are strict MySQL ENUMs (same convention as
-- auth-service); extending one = ALTER ... MODIFY migration + Java enum constant.
-- ============================================================

CREATE TABLE plans (
    id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    code             ENUM('STARTER','TEAM','BUSINESS','ENTERPRISE') NOT NULL,
    name             VARCHAR(64)     NOT NULL,
    description      VARCHAR(255)    NOT NULL,
    price_monthly    INT UNSIGNED    NOT NULL,                -- USD, whole dollars
    max_projects     INT UNSIGNED    NULL,                    -- NULL = unlimited
    max_nodes        INT UNSIGNED    NULL,
    max_automations  INT UNSIGNED    NULL,
    history_days     INT UNSIGNED    NULL,
    trial_days       INT UNSIGNED    NOT NULL DEFAULT 14,
    active           TINYINT(1)      NOT NULL DEFAULT 1,
    sort_order       INT             NOT NULL DEFAULT 0,
    created_at       TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at       TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                     ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_plans_code (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE plan_features (
    plan_id  BIGINT UNSIGNED NOT NULL,
    feature  ENUM('CORE_AUTOMATION','PREMIUM_TEMPLATES','PRIVATE_TEMPLATES',
                  'SSO','ADVANCED_RBAC','AUDIT_LOG','API_ACCESS') NOT NULL,
    PRIMARY KEY (plan_id, feature),
    CONSTRAINT fk_pf_plan FOREIGN KEY (plan_id) REFERENCES plans (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE subscriptions (
    id                    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id             VARCHAR(64)     NOT NULL,
    plan_id               BIGINT UNSIGNED NOT NULL,
    status                ENUM('TRIALING','ACTIVE','PAST_DUE','CANCELED','EXPIRED')
                                          NOT NULL,
    trial_ends_at         TIMESTAMP(6)    NULL,
    current_period_start  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    current_period_end    TIMESTAMP(6)    NOT NULL,
    cancel_at_period_end  TINYINT(1)      NOT NULL DEFAULT 0,
    created_at            TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at            TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                          ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_subscriptions_tenant (tenant_id),          -- one subscription per tenant
    KEY idx_subscriptions_plan (plan_id),
    CONSTRAINT fk_sub_plan FOREIGN KEY (plan_id) REFERENCES plans (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------
-- Seed catalog — mirrors the frontend tier matrix (saasData.js)
-- ------------------------------------------------------------
INSERT INTO plans (code, name, description, price_monthly, max_projects, max_nodes,
                   max_automations, history_days, trial_days, sort_order) VALUES
  ('STARTER',    'Starter',    'Core automation for small teams getting started.',
                 49, 5, 10, 100, 30, 14, 1),
  ('TEAM',       'Team',       'Day-to-day operations for growing teams.',
                 99, 25, 50, 500, 90, 14, 2),
  ('BUSINESS',   'Business',   'Premium templates, advanced RBAC and longer history.',
                 199, 25, 500, 2000, 180, 14, 3),
  ('ENTERPRISE', 'Enterprise', 'Unlimited scale, SSO, private templates and priority support.',
                 399, NULL, NULL, NULL, 730, 14, 4);

INSERT INTO plan_features (plan_id, feature)
SELECT p.id, f.feature FROM plans p
JOIN (
  SELECT 'STARTER' code, 'CORE_AUTOMATION' feature
  UNION ALL SELECT 'TEAM', 'CORE_AUTOMATION'
  UNION ALL SELECT 'TEAM', 'AUDIT_LOG'
  UNION ALL SELECT 'TEAM', 'API_ACCESS'
  UNION ALL SELECT 'BUSINESS', 'CORE_AUTOMATION'
  UNION ALL SELECT 'BUSINESS', 'AUDIT_LOG'
  UNION ALL SELECT 'BUSINESS', 'API_ACCESS'
  UNION ALL SELECT 'BUSINESS', 'PREMIUM_TEMPLATES'
  UNION ALL SELECT 'BUSINESS', 'ADVANCED_RBAC'
  UNION ALL SELECT 'ENTERPRISE', 'CORE_AUTOMATION'
  UNION ALL SELECT 'ENTERPRISE', 'AUDIT_LOG'
  UNION ALL SELECT 'ENTERPRISE', 'API_ACCESS'
  UNION ALL SELECT 'ENTERPRISE', 'PREMIUM_TEMPLATES'
  UNION ALL SELECT 'ENTERPRISE', 'ADVANCED_RBAC'
  UNION ALL SELECT 'ENTERPRISE', 'PRIVATE_TEMPLATES'
  UNION ALL SELECT 'ENTERPRISE', 'SSO'
) f ON f.code = p.code;
