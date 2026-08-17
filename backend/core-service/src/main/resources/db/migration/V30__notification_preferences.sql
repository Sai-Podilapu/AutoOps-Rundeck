-- ============================================================
-- Per-member notification preferences.
--
-- Categories are the notification KINDS the platform actually publishes
-- (see AppNotification.Kind) rather than an invented taxonomy: muting a
-- category the code never emits would be a switch wired to nothing.
--
-- Rows are exceptions, not a roster. Absent row == subscribed, so a new
-- member needs no bootstrap and a new kind defaults to visible. `muted` is
-- still a column (not merely row presence) so the API can PUT either state
-- idempotently.
--
-- Keyed on `reader` — the JWT subject — exactly like notification_reads,
-- because a preference belongs to a person, not to a tenant.
-- ============================================================

CREATE TABLE notification_preferences (
    tenant_id  VARCHAR(64)  NOT NULL,
    reader     VARCHAR(255) NOT NULL,   -- JWT subject (email)
    kind       ENUM('SYSTEM','ALERT','PROVIDER') NOT NULL,
    muted      TINYINT(1)   NOT NULL DEFAULT 0,
    updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                            ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (tenant_id, reader, kind)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
