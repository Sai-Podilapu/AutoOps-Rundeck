-- ============================================================
-- Governance policy modes. Only the CONFIGURABLE policies are stored;
-- no row = the policy's platform default. RISKY_APPROVAL derives its
-- state live from approval settings and CREDENTIAL_HYGIENE is enforced
-- by design (disconnect purges credentials) — neither is stored here.
-- Violations are always computed live from the tenant's real data,
-- never persisted (fixing the cause clears the violation).
-- ============================================================

CREATE TABLE governance_policies (
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id  VARCHAR(64)     NOT NULL,
    policy     ENUM('SCM_REQUIRED','FAILURE_BUDGET','APPROVAL_SLA') NOT NULL,
    mode       ENUM('ENFORCED','MONITOR','DISABLED') NOT NULL,
    updated_by VARCHAR(255)    NULL,
    updated_at TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
               ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_governance_tenant_policy (tenant_id, policy)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;