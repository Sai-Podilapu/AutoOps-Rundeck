-- ============================================================
-- Two "already told them" markers, so the notification watchdog cannot
-- report the same problem on every sweep.
--
-- Both are needed because MISSED and STALLED describe a state that PERSISTS,
-- unlike FAILED or SUCCEEDED which are transitions. A job that is overdue
-- stays overdue; a run that is stuck stays stuck. Without a marker the
-- watchdog would re-send the same alert every interval until someone
-- intervened, which is the fastest way to train a team to mute the channel.
--
-- Durable columns rather than an in-memory set on purpose: an in-memory set
-- is lost on restart (so a redeploy re-alerts everything) and is per-instance
-- (so every replica alerts separately).
-- ============================================================

-- The next_run_at slot we have already reported as missed. Compared for
-- equality, not recency: when the scheduler recovers it advances next_run_at
-- to a NEW slot, which is legitimately eligible to be missed in its own right.
ALTER TABLE jobs
    ADD COLUMN missed_notified_for TIMESTAMP(6) NULL AFTER next_run_at;

-- When this run was reported as STALLED. Set once; a run is only ever
-- reported stalled a single time, however long it goes on running.
ALTER TABLE runs
    ADD COLUMN stalled_notified_at TIMESTAMP(6) NULL AFTER finished_at;

-- The watchdog scans for runs still RUNNING past a threshold. Without this
-- it is a full table scan of a table that grows with every execution.
CREATE INDEX idx_runs_status_started ON runs (status, started_at);
