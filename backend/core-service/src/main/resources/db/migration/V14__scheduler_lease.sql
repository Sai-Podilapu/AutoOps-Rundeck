-- ============================================================
-- Scheduler leader election: a single-row lease per scheduler name. The
-- instance that holds the unexpired lease polls; everyone else skips the
-- cycle. Claimed/renewed with an atomic UPDATE (or INSERT for the first
-- ever claim) — no advisory locks, works on MySQL and H2 alike, and a dead
-- leader is replaced as soon as its lease expires.
-- ============================================================

CREATE TABLE scheduler_lease (
    name        VARCHAR(32)  NOT NULL,        -- lease name, e.g. 'job-scheduler'
    holder      VARCHAR(128) NOT NULL,        -- instance id (host + boot uuid)
    expires_at  TIMESTAMP(6) NOT NULL,
    PRIMARY KEY (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
