-- ============================================================
-- Enterprise per-tenant SSO (the Enterprise-plan "SSO" feature): each tenant
-- can register ITS OWN OIDC identity provider (Okta, Azure AD, Google
-- Workspace, Keycloak, ...). Login-page domain routing sends matching emails
-- to the tenant's IdP; enforce_sso blocks password/OTP login for MEMBERS
-- (admins keep password login as break-glass).
-- ============================================================

CREATE TABLE tenant_idp_config (
    tenant_id      VARCHAR(64)  NOT NULL,
    issuer         VARCHAR(255) NOT NULL,     -- OIDC issuer (discovery base)
    authorize_url  VARCHAR(255) NOT NULL,
    token_url      VARCHAR(255) NOT NULL,
    userinfo_url   VARCHAR(255) NOT NULL,
    client_id      VARCHAR(255) NOT NULL,     -- the TENANT's app in THEIR IdP
    client_secret  VARCHAR(255) NOT NULL,
    enforce_sso    TINYINT(1)   NOT NULL DEFAULT 0,
    enabled        TINYINT(1)   NOT NULL DEFAULT 1,
    created_at     TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at     TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- One email domain belongs to at most ONE tenant (global uniqueness drives
-- the login-page routing).
CREATE TABLE tenant_idp_domains (
    tenant_id  VARCHAR(64)  NOT NULL,
    domain     VARCHAR(128) NOT NULL,
    PRIMARY KEY (domain),
    KEY idx_idp_domains_tenant (tenant_id),
    CONSTRAINT fk_idp_domain_config FOREIGN KEY (tenant_id)
        REFERENCES tenant_idp_config (tenant_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Type policy: extending an ENUM = ALTER ... MODIFY + Java enum constant.
ALTER TABLE auth_audit_log MODIFY COLUMN event_type
    ENUM('OTP_REQUESTED','OTP_SENT','OTP_DELIVERY_FAILED',
         'LOGIN_SUCCESS','LOGIN_FAILURE','OTP_LOCKOUT',
         'TOKEN_REFRESH','REFRESH_REUSE',
         'LOGOUT','LOGOUT_ALL','SSO_LOGIN',
         'USER_ONBOARDED','USER_OFFBOARDED','RATE_LIMITED',
         'EMAIL_VERIFIED','PASSWORD_RESET','PASSWORD_CHANGED',
         'WORKSPACE_RENAMED','ROLE_CHANGED','IDP_CONFIGURED') NOT NULL;
