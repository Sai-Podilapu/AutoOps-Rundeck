-- ============================================================
-- Tighten the Starter tier (product decision 2026-07-23): 3 projects and
-- 5 automation workflows. Existing over-limit tenants are grandfathered —
-- quota checks block NEW creations only, nothing is deleted.
-- ============================================================

UPDATE plans
SET max_projects = 3,
    max_automations = 5
WHERE code = 'STARTER';
