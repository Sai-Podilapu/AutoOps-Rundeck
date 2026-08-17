-- ============================================================
-- Live credential verification (roadmap item: replace the client-side-only
-- "verify" with a real provider check). The outcome of the last verification
-- is stored on the connection so the Integrations page can show a real,
-- durable status instead of theatre. Message is provider text, truncated.
-- ============================================================

ALTER TABLE cloud_connections
    ADD COLUMN last_verified_at      TIMESTAMP(6) NULL AFTER credentials_enc,
    ADD COLUMN last_verified_ok      TINYINT(1)   NULL AFTER last_verified_at,
    ADD COLUMN last_verified_message VARCHAR(512) NULL AFTER last_verified_ok;