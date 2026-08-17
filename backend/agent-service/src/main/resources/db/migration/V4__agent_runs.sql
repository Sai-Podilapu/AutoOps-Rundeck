-- Agent runs: what happened when an agent was asked to do something.
--
-- Until now `agents` held only the DEFINITION - persona, model, tool
-- allow-list - and nothing executed it. These two tables are the execution
-- record: one row per run, one row per step within it.
--
-- The transcript column is the part that makes an approval gate possible at
-- all. A run that stops to ask a human cannot hold its conversation in memory
-- and wait: the approval arrives minutes or hours later, on a different
-- request, quite possibly against a different instance of this service. So
-- the whole message history is persisted on every step, and resuming is
-- reading it back rather than remembering it.

-- Every id in this schema is BIGINT UNSIGNED (see `agents`). MySQL matches
-- foreign keys on the exact type, signedness included, so a plain BIGINT here
-- fails with errno 3780 rather than being widened silently.
CREATE TABLE agent_runs (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,

    tenant_id       VARCHAR(64)  NOT NULL,
    agent_id        BIGINT UNSIGNED NOT NULL,
    project_id      BIGINT UNSIGNED NOT NULL,

    -- PENDING          queued, nothing sent to the model yet
    -- RUNNING          the loop holds it
    -- AWAITING_APPROVAL a tool call needs a human; approval_reference is set
    -- SUCCEEDED        the model stopped of its own accord
    -- FAILED           see error
    -- CANCELLED        a human stopped it
    status          ENUM('PENDING','RUNNING','AWAITING_APPROVAL',
                         'SUCCEEDED','FAILED','CANCELLED') NOT NULL DEFAULT 'PENDING',

    -- What the caller asked for, and what the agent finally answered.
    input           MEDIUMTEXT   NOT NULL,
    output          MEDIUMTEXT,

    -- The resumable state: the full provider-neutral message history as JSON.
    -- Rewritten at the end of every step so a crash loses at most one step,
    -- and an approval that returns hours later has something to resume from.
    transcript      MEDIUMTEXT,

    -- Copied from the agent at run time rather than joined at read time: an
    -- agent's model can be changed after a run, and the run record has to keep
    -- saying which model actually produced this answer.
    model           VARCHAR(128),
    vendor          VARCHAR(32),

    -- step_count is the loop guard. max_steps is copied per run so tightening
    -- the platform default never retroactively kills a run already in flight.
    step_count      INT          NOT NULL DEFAULT 0,
    max_steps       INT          NOT NULL DEFAULT 12,

    -- Set while status = AWAITING_APPROVAL. The gate is the same artifact the
    -- 66 approval-gated scripts use; this column is how the run finds its way
    -- back to the tool call that raised it.
    approval_reference VARCHAR(64),
    pending_tool_id    VARCHAR(128),

    error           TEXT,

    prompt_tokens     BIGINT NOT NULL DEFAULT 0,
    completion_tokens BIGINT NOT NULL DEFAULT 0,

    created_by      VARCHAR(255),
    created_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    started_at      TIMESTAMP    NULL,
    finished_at     TIMESTAMP    NULL,

    CONSTRAINT fk_agent_runs_agent FOREIGN KEY (agent_id)
        REFERENCES agents (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- The list view is always "runs of this agent, newest first", and the tenant
-- filter is applied on every query because agent ids are not tenant-scoped.
CREATE INDEX ix_agent_runs_agent   ON agent_runs (agent_id, id DESC);
CREATE INDEX ix_agent_runs_tenant  ON agent_runs (tenant_id, id DESC);

-- The resume path looks a run up BY its approval reference, so this index is
-- on the lookup key rather than the run id.
CREATE INDEX ix_agent_runs_approval ON agent_runs (approval_reference);


CREATE TABLE agent_run_steps (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    run_id          BIGINT UNSIGNED NOT NULL,

    -- Monotonic within a run. Ordering by id would work today and break the
    -- moment steps are ever written out of order or backfilled.
    seq             INT          NOT NULL,

    -- MODEL_CALL         a request to the model and what it returned
    -- TOOL_CALL          the agent asked for a tool
    -- TOOL_RESULT        what the tool returned (or the error it raised)
    -- APPROVAL_REQUESTED the run stopped here for a human
    -- APPROVAL_GRANTED   a human released it
    kind            ENUM('MODEL_CALL','TOOL_CALL','TOOL_RESULT',
                         'APPROVAL_REQUESTED','APPROVAL_GRANTED') NOT NULL,

    -- Null on MODEL_CALL rows. tool_type mirrors the allow-list vocabulary
    -- ('JOB' | 'WORKFLOW') so a step can be matched back to the entry that
    -- authorised it.
    tool_type       VARCHAR(16),
    tool_target_id  BIGINT UNSIGNED,
    tool_name       VARCHAR(255),

    -- The provider-neutral view of what was sent and what came back. Kept as
    -- text rather than parsed columns because the shape differs per vendor and
    -- the audit value is in having the verbatim exchange.
    request         MEDIUMTEXT,
    response        MEDIUMTEXT,

    -- A failed tool is a step that HAPPENED, not a step that is missing. The
    -- model is told about the failure and gets to react to it, so the row is
    -- written either way and this flag is how a reader tells them apart.
    is_error        BOOLEAN      NOT NULL DEFAULT FALSE,

    duration_ms     BIGINT,
    created_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_agent_run_steps_run FOREIGN KEY (run_id)
        REFERENCES agent_runs (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE UNIQUE INDEX uq_agent_run_steps_seq ON agent_run_steps (run_id, seq);
