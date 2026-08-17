-- ============================================================
-- API keys (API_ACCESS plan feature, Team+): per-user machine credentials.
-- Only the SHA-256 hash is stored — the raw key is shown exactly once at
-- creation. Keys are exchanged for short-lived access tokens at
-- POST /api/auth/token/api-key; revocation kills the key immediately.
-- Also: PROFILE_UPDATED / API_KEY_* audit event values.
-- ============================================================

CREATE TABLE api_keys (
    id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id    VARCHAR(64)     NOT NULL,
    user_id      BIGINT UNSIGNED NOT NULL,
    name         VARCHAR(128)    NOT NULL,
    prefix       CHAR(12)        NOT NULL,      -- displayable identifier ak_XXXXXXXX
    key_hash     CHAR(64)        NOT NULL,      -- SHA-256 hex of the full key
    created_at   TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    last_used_at TIMESTAMP(6)    NULL,
    revoked_at   TIMESTAMP(6)    NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_api_keys_hash (key_hash),
    KEY idx_api_keys_tenant (tenant_id),
    CONSTRAINT fk_api_keys_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

ALTER TABLE auth_audit_log
    MODIFY event_type ENUM('OTP_REQUESTED','OTP_SENT','OTP_DELIVERY_FAILED',
        'LOGIN_SUCCESS','LOGIN_FAILURE','OTP_LOCKOUT',
        'TOKEN_REFRESH','REFRESH_REUSE',
        'LOGOUT','LOGOUT_ALL','SSO_LOGIN',
        'USER_ONBOARDED','USER_OFFBOARDED','RATE_LIMITED',
        'EMAIL_VERIFIED','PASSWORD_RESET','PASSWORD_CHANGED',
        'WORKSPACE_RENAMED','ROLE_CHANGED','IDP_CONFIGURED',
        'PROFILE_UPDATED','API_KEY_CREATED','API_KEY_REVOKED') NOT NULL;
