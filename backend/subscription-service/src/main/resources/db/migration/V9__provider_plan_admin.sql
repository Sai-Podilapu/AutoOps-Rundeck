-- ============================================================
-- Provider plan administration: PROVIDER accounts can edit plan pricing,
-- limits and availability through /api/provider/plans/{code}. Those edits
-- are audited as PLAN_UPDATED (distinct from a tenant's PLAN_CHANGED).
-- ============================================================

ALTER TABLE subscription_audit_log
    MODIFY event_type ENUM('SUBSCRIBED','PLAN_CHANGED','REACTIVATED','CANCELED',
                           'PAYMENT_SUCCEEDED','PAYMENT_FAILED','PLAN_UPDATED') NOT NULL;
