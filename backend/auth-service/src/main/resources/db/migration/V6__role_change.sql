-- ============================================================
-- Team management: admins can change a member's role. Type policy:
-- extending an ENUM = ALTER ... MODIFY + Java enum constant.
-- ============================================================

ALTER TABLE auth_audit_log MODIFY COLUMN event_type
    ENUM('OTP_REQUESTED','OTP_SENT','OTP_DELIVERY_FAILED',
         'LOGIN_SUCCESS','LOGIN_FAILURE','OTP_LOCKOUT',
         'TOKEN_REFRESH','REFRESH_REUSE',
         'LOGOUT','LOGOUT_ALL','SSO_LOGIN',
         'USER_ONBOARDED','USER_OFFBOARDED','RATE_LIMITED',
         'EMAIL_VERIFIED','PASSWORD_RESET','PASSWORD_CHANGED',
         'WORKSPACE_RENAMED','ROLE_CHANGED') NOT NULL;
