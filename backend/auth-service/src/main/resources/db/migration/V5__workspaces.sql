-- ============================================================
-- Workspace display names. Until now the name typed at sign-up only seeded
-- the tenant_id slug; the human-readable name was lost. tenants stores it so
-- /api/auth/me can return it and admins can rename their workspace.
-- No backfill: pre-existing tenants have no stored name and clients fall
-- back to prettifying the slug.
-- ============================================================

CREATE TABLE tenants (
    tenant_id    VARCHAR(64)  NOT NULL,
    display_name VARCHAR(128) NOT NULL,
    created_at   TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at   TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                              ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Type policy: extending an ENUM = ALTER ... MODIFY + Java enum constant.
ALTER TABLE auth_audit_log MODIFY COLUMN event_type
    ENUM('OTP_REQUESTED','OTP_SENT','OTP_DELIVERY_FAILED',
         'LOGIN_SUCCESS','LOGIN_FAILURE','OTP_LOCKOUT',
         'TOKEN_REFRESH','REFRESH_REUSE',
         'LOGOUT','LOGOUT_ALL','SSO_LOGIN',
         'USER_ONBOARDED','USER_OFFBOARDED','RATE_LIMITED',
         'EMAIL_VERIFIED','PASSWORD_RESET','PASSWORD_CHANGED',
         'WORKSPACE_RENAMED') NOT NULL;
