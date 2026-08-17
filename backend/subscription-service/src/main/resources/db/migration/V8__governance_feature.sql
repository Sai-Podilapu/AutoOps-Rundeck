-- ============================================================
-- GOVERNANCE feature: policy engine + governance dashboard in
-- core-service. Granted to Business and Enterprise, matching the
-- frontend entitlement matrix (governance requires the Business plan).
-- ============================================================

ALTER TABLE plan_features
    MODIFY feature ENUM('CORE_AUTOMATION','PREMIUM_TEMPLATES','PRIVATE_TEMPLATES',
                        'SSO','ADVANCED_RBAC','AUDIT_LOG','API_ACCESS',
                        'COMPLIANCE_REPORTS','GOVERNANCE') NOT NULL;

INSERT INTO plan_features (plan_id, feature)
SELECT id, 'GOVERNANCE' FROM plans WHERE code IN ('BUSINESS', 'ENTERPRISE');