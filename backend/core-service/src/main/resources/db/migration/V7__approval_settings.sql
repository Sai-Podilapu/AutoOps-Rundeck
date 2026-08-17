-- ============================================================
-- Per-tenant approval tuning. The workflow-complexity node threshold
-- (default 5, see WorkflowComplexity) becomes overridable per tenant by
-- its admins. No row = platform default. Risky node types stay fixed.
-- ============================================================

CREATE TABLE approval_settings (
    tenant_id              VARCHAR(64)  NOT NULL,
    complex_node_threshold INT UNSIGNED NOT NULL DEFAULT 5,
    updated_by             VARCHAR(255) NULL,
    updated_at             TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                           ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;