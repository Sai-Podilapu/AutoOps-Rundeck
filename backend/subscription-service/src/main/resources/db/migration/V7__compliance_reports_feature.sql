-- ============================================================
-- COMPLIANCE_REPORTS feature: audit-ready compliance reporting in
-- core-service. Granted to Business and Enterprise, matching the
-- frontend entitlement matrix (compliance requires the Business plan).
-- ============================================================

ALTER TABLE plan_features
    MODIFY feature ENUM('CORE_AUTOMATION','PREMIUM_TEMPLATES','PRIVATE_TEMPLATES',
                        'SSO','ADVANCED_RBAC','AUDIT_LOG','API_ACCESS',
                        'COMPLIANCE_REPORTS') NOT NULL;

INSERT INTO plan_features (plan_id, feature)
SELECT id, 'COMPLIANCE_REPORTS' FROM plans WHERE code IN ('BUSINESS', 'ENTERPRISE');