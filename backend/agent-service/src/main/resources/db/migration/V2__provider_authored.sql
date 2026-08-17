-- ============================================================
-- Provider-authored agents. Mirrors workflow-service V2.
--
--   origin     TENANT   = built inside the workspace (legacy rows only; the
--                         API no longer creates these)
--              PROVIDER = rolled out from the platform catalog. `instructions`
--                         — the operating brief that IS the product — is
--                         withheld from non-PROVIDER callers.
--   source_id  the library_items row it was rolled out from.
--
-- What stays visible on a sealed agent, deliberately:
--   * tools      — the allow-list bounds what the agent may touch. A customer
--                  who cannot see it cannot consent to it, and this is the
--                  security boundary, so it is disclosed even when sealed.
--   * model      — customers are entitled to know what runs over their data.
-- Only the persona is withheld.
-- ============================================================

ALTER TABLE agents
    ADD COLUMN origin    ENUM('TENANT','PROVIDER') NOT NULL DEFAULT 'TENANT' AFTER project_id,
    ADD COLUMN source_id BIGINT UNSIGNED           NULL                      AFTER origin;

CREATE INDEX idx_agents_source ON agents (source_id);
