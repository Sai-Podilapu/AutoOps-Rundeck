-- DST fall-back de-duplication.
--
-- On the fall-back day a local wall-clock time happens TWICE (America/Chicago
-- 2026-11-01 runs 01:00-02:00 at -05:00, then again at -06:00). Both are
-- legitimately distinct instants, so the cron resolves to both and a daily
-- 01:30 job fires twice, an hour apart, on the same local date.
--
-- This column records the local wall-clock slot a run was last QUEUED for.
-- The scheduler skips a due job whose slot equals it, which collapses the
-- duplicated hour to a single run while leaving every normal slot untouched
-- (consecutive slots always differ in local date or time).
--
-- DATETIME, deliberately NOT TIMESTAMP: this is a wall-clock reading in the
-- job's own zone, and MySQL must not convert it. It is meaningless without
-- jobs.schedule_timezone, and is cleared whenever that zone changes.
ALTER TABLE jobs
    ADD COLUMN last_fired_local DATETIME(6) NULL AFTER schedule_timezone;
