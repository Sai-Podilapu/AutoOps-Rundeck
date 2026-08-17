-- Per-job schedule timezone.
--
-- jobs.schedule is a LOCAL-TIME rule; this column says which zone that local
-- time belongs to. next_run_at stays an absolute UTC instant — only the
-- INTERPRETATION of the cron changes, never how a due row is claimed.
--
-- Values are IANA zone IDs ("America/Chicago"), never abbreviations ("CST")
-- and never fixed offsets ("-06:00"). Only a Region/City ID carries DST rules:
-- a fixed offset silently drifts an hour at the next transition, and "MST"
-- cannot distinguish America/Denver (shifts to MDT) from America/Phoenix
-- (never shifts) — java.time.ZoneId.SHORT_IDS in fact maps MST to a fixed
-- -07:00, i.e. the Phoenix answer. CronSupport.zone() enforces this.
--
-- DEFAULT 'UTC' keeps every existing job firing at exactly the same instant
-- it does today. This migration must not move anyone's schedule.
ALTER TABLE jobs
    ADD COLUMN schedule_timezone VARCHAR(64) NOT NULL DEFAULT 'UTC' AFTER schedule;
