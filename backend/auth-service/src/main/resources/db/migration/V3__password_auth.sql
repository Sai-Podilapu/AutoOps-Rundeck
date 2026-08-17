-- ------------------------------------------------------------
-- V3__password_auth.sql
-- Adds password-based login/registration alongside passwordless OTP.
-- password_hash is NULL for OTP-only / SSO-linked accounts; a BCrypt
-- hash when the account was created with (or set) a password.
-- ------------------------------------------------------------

ALTER TABLE users
    ADD COLUMN password_hash VARCHAR(255) NULL AFTER full_name;