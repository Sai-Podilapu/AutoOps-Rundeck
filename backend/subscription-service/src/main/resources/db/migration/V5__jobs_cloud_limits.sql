-- ============================================================
-- Jobs and cloud integrations join the quota model (product decision
-- 2026-07-23): they are core building blocks and must be plan-limited.
-- NULL keeps meaning unlimited (custom/negotiated plans only).
-- ============================================================

ALTER TABLE plans
    ADD COLUMN max_jobs               INT UNSIGNED NULL AFTER max_automations,
    ADD COLUMN max_cloud_integrations INT UNSIGNED NULL AFTER max_jobs;

UPDATE plans SET max_jobs = 5,  max_cloud_integrations = 2  WHERE code = 'STARTER';
UPDATE plans SET max_jobs = 10, max_cloud_integrations = 5  WHERE code = 'TEAM';
UPDATE plans SET max_jobs = 25, max_cloud_integrations = 5  WHERE code = 'BUSINESS';
UPDATE plans SET max_jobs = 30, max_cloud_integrations = 10 WHERE code = 'ENTERPRISE';
