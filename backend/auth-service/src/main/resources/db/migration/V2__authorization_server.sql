
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
