-- ============================================================
-- Pricing/capacity revision (product decision 2026-07-23):
-- Starter $59 (limits unchanged from V3), Team $149 10/15/25,
-- Business $299 25/25/35, Enterprise $399 30/30/50.
-- Enterprise is NO LONGER unlimited — every tier has a capacity ceiling;
-- the ladder grows at every step. Existing over-limit tenants are
-- grandfathered (quota checks block NEW creations only).
-- ============================================================

UPDATE plans SET price_monthly = 59
WHERE code = 'STARTER';

UPDATE plans SET price_monthly = 149, max_projects = 10, max_automations = 15, max_nodes = 25
WHERE code = 'TEAM';

UPDATE plans SET price_monthly = 299, max_projects = 25, max_automations = 25, max_nodes = 35
WHERE code = 'BUSINESS';

UPDATE plans SET price_monthly = 399, max_projects = 30, max_automations = 30, max_nodes = 50,
    description = 'Maximum capacity with SSO, private templates and priority support.'
WHERE code = 'ENTERPRISE';
