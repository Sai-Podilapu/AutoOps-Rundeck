-- ============================================================
-- The values a person supplied when they triggered a run.
--
-- A Dify-backed workflow declares an input form (its start-node variables),
-- and the customer fills it in before the run starts. Those values have to
-- live on the run rather than on the workflow: the workflow is one thing,
-- rolled out once, and every run of it answers different questions.
--
-- Nullable because most runs have none — a job, a scheduled trigger, a
-- workflow with no declared inputs. NULL means "none supplied", which is
-- distinct from '{}' meaning "the form was shown and left empty".
--
-- TEXT, not JSON: MySQL's JSON type would reformat and reorder keys on the
-- way in, and this column is also read back as the audit record of what the
-- operator actually typed.
-- ============================================================

ALTER TABLE runs
    ADD COLUMN inputs TEXT NULL AFTER definition;

-- A complex workflow run by a non-admin becomes a PENDING approval and is
-- replayed later, by the approver, from the approval row alone. Without the
-- values parked here the replay would run the workflow with an empty form --
-- and an empty form usually succeeds and produces nonsense rather than
-- failing, so nobody would notice.
ALTER TABLE approvals
    ADD COLUMN inputs TEXT NULL AFTER target_name;
