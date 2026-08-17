-- ============================================================
-- AutoOps auth-service — MySQL schema (database: autoops_auth)
-- Managed by Flyway. Split across two migrations:
--   V1__init.sql                 (core auth tables)
--   V2__authorization_server.sql (Spring Authorization Server)
-- spring.jpa.hibernate.ddl-auto = validate
--
-- TYPE POLICY (v2.1):
--   * Closed value sets are strict MySQL ENUMs — never raw VARCHAR.
--     Invalid values are rejected at the database layer.
--   * JPA mapping: Java enum + @Enumerated(EnumType.STRING) with
--     columnDefinition matching the ENUM below.
--   * Adding a new value = Flyway migration:
--     ALTER TABLE <t> MODIFY <col> ENUM(...) — plus the Java enum constant.
--   * Exception: oauth2_* tables (V2) keep Spring Authorization Server's
--     framework-standard schema; SAS owns those columns, do not alter them.
-- ============================================================

-- ------------------------------------------------------------
-- V1__init.sql
-- ------------------------------------------------------------

CREATE TABLE users (
    id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    email             VARCHAR(255)    NOT NULL,
    full_name         VARCHAR(255)    NULL,
    role              ENUM('PROVIDER','CLIENT','ADMIN')
                                      NOT NULL,
    status            ENUM('ACTIVE','PENDING','DISABLED')
                                      NOT NULL DEFAULT 'ACTIVE',
    tenant_id         VARCHAR(64)     NOT NULL,
    token_version     INT UNSIGNED    NOT NULL DEFAULT 0,      -- bumped on logout-all / offboard
    keycloak_subject  VARCHAR(64)     NULL,                    -- OIDC sub when SSO-linked
    created_at        TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at        TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                      ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_users_email_tenant (email, tenant_id),
    KEY idx_users_tenant (tenant_id),
    KEY idx_users_keycloak_subject (keycloak_subject)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE otp_entries (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    email         VARCHAR(255)    NOT NULL,
    tenant_id     VARCHAR(64)     NOT NULL,
    otp_hash      CHAR(64)        NOT NULL,          -- SHA-256 hex; plaintext is NEVER stored
    attempts      INT UNSIGNED    NOT NULL DEFAULT 0,
    max_attempts  INT UNSIGNED    NOT NULL DEFAULT 5,
    expires_at    TIMESTAMP(6)    NOT NULL,          -- typically now + 5 minutes
    consumed_at   TIMESTAMP(6)    NULL,              -- set on successful verify
    locked_at     TIMESTAMP(6)    NULL,              -- set when attempts >= max_attempts
    delivery_status ENUM('PENDING','SENT','DELIVERED','BOUNCED','FAILED')
                                  NOT NULL DEFAULT 'PENDING', -- SendGrid delivery lifecycle
    sendgrid_message_id VARCHAR(128) NULL,           -- X-Message-Id from SendGrid v3 Mail Send;
                                                     -- correlates Event Webhook callbacks
    created_at    TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_otp_email_tenant (email, tenant_id),
    KEY idx_otp_expires (expires_at),
    KEY idx_otp_sendgrid_msg (sendgrid_message_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE refresh_token_sessions (
    session_id          CHAR(36)        NOT NULL,    -- UUID (public half of the token)
    user_id             BIGINT UNSIGNED NOT NULL,
    tenant_id           VARCHAR(64)     NOT NULL,
    token_hash          CHAR(64)        NOT NULL,    -- SHA-256 hex of the 48-byte secret half
    device_id           VARCHAR(128)    NULL,
    ip_address          VARCHAR(45)     NULL,        -- IPv4/IPv6 (resolved via XFF chain)
    user_agent          VARCHAR(512)    NULL,
    issued_at           TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    expires_at          TIMESTAMP(6)    NOT NULL,    -- typically now + 30 days
    revoked_at          TIMESTAMP(6)    NULL,
    replaced_by_session CHAR(36)        NULL,        -- rotation chain link
    reuse_detected      TINYINT(1)      NOT NULL DEFAULT 0, -- 1 => rotated token was replayed
    PRIMARY KEY (session_id),
    KEY idx_rts_user (user_id),
    KEY idx_rts_user_device (user_id, device_id),
    KEY idx_rts_expires (expires_at),
    CONSTRAINT fk_rts_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE auth_audit_log (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    event_type  ENUM(
                    'OTP_REQUESTED','OTP_SENT','OTP_DELIVERY_FAILED',
                    'LOGIN_SUCCESS','LOGIN_FAILURE','OTP_LOCKOUT',
                    'TOKEN_REFRESH','REFRESH_REUSE',
                    'LOGOUT','LOGOUT_ALL','SSO_LOGIN',
                    'USER_ONBOARDED','USER_OFFBOARDED','RATE_LIMITED'
                )               NOT NULL,
    user_id     BIGINT UNSIGNED NULL,
    email       VARCHAR(255)    NULL,
    tenant_id   VARCHAR(64)     NULL,
    session_id  CHAR(36)        NULL,
    ip_address  VARCHAR(45)     NULL,
    user_agent  VARCHAR(512)    NULL,
    detail      VARCHAR(1024)   NULL,      -- JSON or free text, no secrets
    created_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_audit_user (user_id),
    KEY idx_audit_event_time (event_type, created_at),
    KEY idx_audit_tenant (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------
-- V2__authorization_server.sql
-- Spring Authorization Server tables (used when TOKEN_STORE=jdbc).
-- Standard SAS schema, trimmed to the columns SAS requires.
-- ------------------------------------------------------------

CREATE TABLE oauth2_registered_client (
    id                            VARCHAR(100)  NOT NULL,
    client_id                     VARCHAR(100)  NOT NULL,
    client_id_issued_at           TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    client_secret                 VARCHAR(200)  NULL,      -- bcrypt-encoded
    client_secret_expires_at      TIMESTAMP     NULL,
    client_name                   VARCHAR(200)  NOT NULL,
    client_authentication_methods VARCHAR(1000) NOT NULL,
    authorization_grant_types     VARCHAR(1000) NOT NULL,
    redirect_uris                 VARCHAR(1000) NULL,
    post_logout_redirect_uris     VARCHAR(1000) NULL,
    scopes                        VARCHAR(1000) NOT NULL,
    client_settings               VARCHAR(2000) NOT NULL,
    token_settings                VARCHAR(2000) NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_orc_client_id (client_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE oauth2_authorization (
    id                            VARCHAR(100)  NOT NULL,
    registered_client_id          VARCHAR(100)  NOT NULL,
    principal_name                VARCHAR(200)  NOT NULL,
    authorization_grant_type      VARCHAR(100)  NOT NULL,
    authorized_scopes             VARCHAR(1000) NULL,
    attributes                    BLOB          NULL,
    state                         VARCHAR(500)  NULL,
    authorization_code_value      BLOB          NULL,
    authorization_code_issued_at  TIMESTAMP     NULL,
    authorization_code_expires_at TIMESTAMP     NULL,
    authorization_code_metadata   BLOB          NULL,
    access_token_value            BLOB          NULL,
    access_token_issued_at        TIMESTAMP     NULL,
    access_token_expires_at       TIMESTAMP     NULL,
    access_token_metadata         BLOB          NULL,
    access_token_type             VARCHAR(100)  NULL,
    access_token_scopes           VARCHAR(1000) NULL,
    refresh_token_value           BLOB          NULL,
    refresh_token_issued_at       TIMESTAMP     NULL,
    refresh_token_expires_at      TIMESTAMP     NULL,
    refresh_token_metadata        BLOB          NULL,
    oidc_id_token_value           BLOB          NULL,
    oidc_id_token_issued_at       TIMESTAMP     NULL,
    oidc_id_token_expires_at      TIMESTAMP     NULL,
    oidc_id_token_metadata        BLOB          NULL,
    oidc_id_token_claims          VARCHAR(2000) NULL,
    user_code_value               BLOB          NULL,
    user_code_issued_at           TIMESTAMP     NULL,
    user_code_expires_at          TIMESTAMP     NULL,
    user_code_metadata            BLOB          NULL,
    device_code_value             BLOB          NULL,
    device_code_issued_at         TIMESTAMP     NULL,
    device_code_expires_at        TIMESTAMP     NULL,
    device_code_metadata          BLOB          NULL,
    PRIMARY KEY (id),
    KEY idx_oa_principal (principal_name),
    KEY idx_oa_client (registered_client_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Seed the gateway introspection client (secret must be bcrypt-encoded at deploy time)
-- INSERT INTO oauth2_registered_client (id, client_id, client_secret, client_name,
--     client_authentication_methods, authorization_grant_types, scopes,
--     client_settings, token_settings)
-- VALUES (UUID(), 'gateway', '{bcrypt}$2a$10$REPLACE_ME', 'AutoOps API Gateway',
--     'client_secret_basic', 'client_credentials', 'introspect',
--     '{"@class":"java.util.Collections$UnmodifiableMap","settings.client.require-proof-key":false,"settings.client.require-authorization-consent":false}',
--     '{"@class":"java.util.Collections$UnmodifiableMap","settings.token.access-token-time-to-live":["java.time.Duration",900.000000000]}');
