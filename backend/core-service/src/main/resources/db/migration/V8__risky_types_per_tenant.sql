-- ============================================================
-- Risky node types become per-tenant too. CSV list; NULL = platform
-- default set (see WorkflowComplexity.RISKY_TYPES), empty string = the
-- tenant explicitly disabled risky-type gating (node-count threshold
-- still applies).
-- ============================================================

ALTER TABLE approval_settings
    ADD COLUMN risky_types VARCHAR(1024) NULL AFTER complex_node_threshold;
