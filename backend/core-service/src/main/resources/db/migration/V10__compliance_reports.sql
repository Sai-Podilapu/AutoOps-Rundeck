-- ============================================================
-- Compliance reports: point-in-time control evaluations of a project's
-- REAL posture (approval gating, credential handling, run history, SCM,
-- retention) against a framework's control set. The full findings are
-- SNAPSHOTTED as JSON in `content` so a report stays audit-stable even
-- as the project changes; no FK to projects (same convention as runs —
-- history survives archival).
-- ============================================================

CREATE TABLE compliance_reports (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id      VARCHAR(64)     NOT NULL,
    project_id     BIGINT UNSIGNED NOT NULL,
    framework      ENUM('SOC2','ISO_27001','HIPAA','PCI_DSS','GDPR') NOT NULL,
    status         ENUM('COMPLIANT','NON_COMPLIANT') NOT NULL,
    score          INT UNSIGNED    NOT NULL,                -- 0..100
    controls_total INT UNSIGNED    NOT NULL,
    passed         INT UNSIGNED    NOT NULL,
    warnings       INT UNSIGNED    NOT NULL,
    failed         INT UNSIGNED    NOT NULL,
    content        MEDIUMTEXT      NOT NULL,                -- findings JSON snapshot
    generated_by   VARCHAR(255)    NULL,
    created_at     TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_compliance_tenant_project (tenant_id, project_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;