-- ============================================================
-- Provider-authored workflows.
--
-- Designing workflows is the PROVIDER's job, not the tenant's: the canvas is
-- the product being sold, so a customer receives a workflow they can run,
-- enable and audit — never one they can read or edit. Two columns carry that:
--
--   origin     TENANT   = authored inside the workspace (legacy rows only;
--                         the API no longer creates these)
--              PROVIDER = rolled out from the platform catalog. The API
--                         REFUSES to return `definition` for these rows to a
--                         non-PROVIDER caller (see WorkflowResponse.from) —
--                         the run engine still reads it over /internal, which
--                         never leaves the server.
--   source_id  the library_items row in core-service this was rolled out
--              from, so a catalog edit can find every copy it produced.
--              No FK: library_items lives in another service's database.
--
-- Existing rows default to TENANT so nothing silently becomes sealed; the
-- Intertec demo set is converted deliberately by demo-data/seed-intertec.sql.
-- ============================================================

ALTER TABLE workflows
    ADD COLUMN origin    ENUM('TENANT','PROVIDER') NOT NULL DEFAULT 'TENANT' AFTER project_id,
    ADD COLUMN source_id BIGINT UNSIGNED           NULL                      AFTER origin;

-- The provider console's "who has this rolled out?" view reads by catalog id.
CREATE INDEX idx_workflows_source ON workflows (source_id);