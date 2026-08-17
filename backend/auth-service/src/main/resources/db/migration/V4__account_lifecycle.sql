-- ------------------------------------------------------------
-- V4__account_lifecycle.sql
-- Email verification + password reset/change support:
--   * new audit event types (type policy: extending an ENUM value set is a
--     Flyway MODIFY plus the matching Java enum constant)
-- Self-registered users now start as PENDING and are activated by verifying
-- an emailed code ('PENDING' already exists in users.status since V1).
-- ------------------------------------------------------------

ALTER TABLE auth_audit_log
    MODIFY event_type ENUM(
        'OTP_REQUESTED','OTP_SENT','OTP_DELIVERY_FAILED',
        'LOGIN_SUCCESS','LOGIN_FAILURE','OTP_LOCKOUT',
        'TOKEN_REFRESH','REFRESH_REUSE',
        'LOGOUT','LOGOUT_ALL','SSO_LOGIN',
        'USER_ONBOARDED','USER_OFFBOARDED','RATE_LIMITED',
        'EMAIL_VERIFIED','PASSWORD_RESET','PASSWORD_CHANGED'
    ) NOT NULL;
