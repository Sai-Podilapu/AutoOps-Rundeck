-- ============================================================
-- Payment records. Provider-agnostic: `provider` names which PaymentProvider
-- implementation charged (STUB today, STRIPE later) and `provider_ref` holds
-- its external reference (e.g. a Stripe PaymentIntent id). Rows are written
-- once per charge attempt and never mutated afterwards — a retry is a NEW row.
-- ============================================================

CREATE TABLE payments (
    id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id       VARCHAR(64)     NOT NULL,
    subscription_id BIGINT UNSIGNED NOT NULL,
    provider        ENUM('STUB','STRIPE') NOT NULL,
    provider_ref    VARCHAR(128)    NULL,          -- external charge/intent id
    plan_code       ENUM('STARTER','TEAM','BUSINESS','ENTERPRISE') NOT NULL,
    amount_cents    INT UNSIGNED    NOT NULL,
    currency        CHAR(3)         NOT NULL DEFAULT 'USD',
    status          ENUM('PENDING','SUCCEEDED','FAILED','REFUNDED') NOT NULL,
    failure_reason  VARCHAR(255)    NULL,          -- provider error; never card data
    period_start    TIMESTAMP(6)    NOT NULL,
    period_end      TIMESTAMP(6)    NOT NULL,
    created_at      TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at      TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                    ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_payments_tenant (tenant_id, created_at),
    KEY idx_payments_subscription (subscription_id),
    CONSTRAINT fk_payment_subscription FOREIGN KEY (subscription_id) REFERENCES subscriptions (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Type policy: extending an ENUM = ALTER ... MODIFY + Java enum constant.
ALTER TABLE subscription_audit_log MODIFY COLUMN event_type
    ENUM('SUBSCRIBED','PLAN_CHANGED','REACTIVATED','CANCELED',
         'PAYMENT_SUCCEEDED','PAYMENT_FAILED') NOT NULL;
