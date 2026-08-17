-- An agent can now start a run, so the run history needs a way to say so.
--
-- Without this the agent's runs would have to claim MANUAL, and the run list
-- would tell an operator a person pressed Run when nobody did. That is exactly
-- the kind of quiet lie an audit trail cannot afford: the whole point of
-- trigger_type is answering "who started this".
ALTER TABLE runs
    MODIFY trigger_type ENUM('MANUAL','SCHEDULE','WEBHOOK','AGENT') NOT NULL DEFAULT 'MANUAL';
