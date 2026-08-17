-- ============================================================
-- Subscription audit trail — best-effort billing event log written by
-- AuditService (same convention as auth-service's auth_audit_log):
-- strict ENUM event types, DB-managed created_at, rows are never updated.
-- ============================================================

CREATE TABLE subscription_audit_log (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    event_type  ENUM('SUBSCRIBED','PLAN_CHANGED','REACTIVATED','CANCELED') NOT NULL,
    tenant_id   VARCHAR(64)     NOT NULL,
    plan_code   ENUM('STARTER','TEAM','BUSINESS','ENTERPRISE') NULL,  -- plan involved, if any
    actor       VARCHAR(255)    NULL,           -- JWT subject (email) of the admin acting
    detail      VARCHAR(1024)   NULL,           -- free text; must never contain tokens
    created_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_sub_audit_tenant (tenant_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
