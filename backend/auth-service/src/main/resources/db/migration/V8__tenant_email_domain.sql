-- ============================================================
-- One organization per corporate email domain. tenants.email_domain is the
-- claim: globally UNIQUE, set only once an admin at that domain has a
-- VERIFIED email (self-register verify step, or provider-verified social
-- sign-up). Free mailbox providers (gmail/outlook/...) never claim a domain.
-- Backfill: each existing verified tenant claims its earliest ACTIVE admin's
-- domain; where several tenants already share a domain the OLDEST wins and
-- the rest stay unclaimed (grandfathered, nothing is deleted).
-- ============================================================

ALTER TABLE tenants
    ADD COLUMN email_domain VARCHAR(255) NULL AFTER display_name,
    ADD UNIQUE KEY uq_tenants_email_domain (email_domain);

UPDATE tenants t
JOIN (
    SELECT tenant_id, domain FROM (
        SELECT a.tenant_id, a.domain,
               ROW_NUMBER() OVER (PARTITION BY a.domain ORDER BY a.first_seen, a.tenant_id) AS rn
        FROM (
            SELECT u.tenant_id,
                   LOWER(SUBSTRING_INDEX(u.email, '@', -1)) AS domain,
                   MIN(u.created_at) AS first_seen
            FROM users u
            WHERE u.role = 'ADMIN' AND u.status = 'ACTIVE'
            GROUP BY u.tenant_id, LOWER(SUBSTRING_INDEX(u.email, '@', -1))
        ) a
        WHERE a.domain NOT IN (
            'gmail.com','googlemail.com','yahoo.com','yahoo.co.in','ymail.com',
            'outlook.com','hotmail.com','live.com','msn.com',
            'icloud.com','me.com','mac.com','aol.com',
            'proton.me','protonmail.com','pm.me','zoho.com','zohomail.in',
            'gmx.com','gmx.net','mail.com','yandex.com','yandex.ru','rediffmail.com'
        )
    ) ranked
    WHERE ranked.rn = 1
) d ON d.tenant_id = t.tenant_id
SET t.email_domain = d.domain;
