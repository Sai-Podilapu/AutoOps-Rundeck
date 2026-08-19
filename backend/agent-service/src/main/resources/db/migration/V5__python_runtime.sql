-- The Python reasoning runtime.
--
-- The reasoning moves to a separate, stateless service; this service keeps the
-- loop, the approvals and the audit trail. Three groups of columns fall out of
-- that split.
--
-- 1. WHICH AGENT the runtime should run. A Python-authored agent's persona and
--    graph live in the runtime's image, never in a customer's database, so the
--    row holds a REFERENCE rather than the product. `graph_ref` NULL means the
--    agent is still a JSON persona and runs on the single-phase compatibility
--    graph — which is every agent that exists today.
--
-- 2. WHAT THE RUN IS DOING, for the run view and for tracing.
--
-- 3. THE PARTIAL TURN. This is the one that is easy to underestimate. The
--    `transcript` column used to hold a message list this service wrote and
--    read; it now holds an opaque state blob the runtime owns. So the
--    bookkeeping that used to live inside that list — "the model asked for
--    three tools, the second needs a human, here are the two results I already
--    have" — has nowhere to go and needs columns of its own. Without them a run
--    that parks on the second of three tool calls would, on resume, either lose
--    the first result or run the first tool a second time.

ALTER TABLE agents
    -- Which module in the runtime's registry. NULL = the legacy JSON path.
    ADD COLUMN graph_ref     VARCHAR(128) NULL AFTER model,
    -- The version this tenant was rolled out with. The runtime runs its own
    -- current version and REPORTS a substitution rather than refusing, because
    -- a strict match would break every tenant the moment the provider shipped
    -- an update. This column is what makes the substitution auditable.
    ADD COLUMN graph_version VARCHAR(32)  NULL AFTER graph_ref;

ALTER TABLE agent_runs
    -- TRIAGE, GATHER, HYPOTHESIZE, PLAN, GATE, ACT, VERIFY, REPORT, DONE, or
    -- RESPOND for the legacy single-phase graph. Deliberately VARCHAR and not
    -- an ENUM: the phase vocabulary belongs to the runtime, and an ENUM here
    -- would mean a schema migration every time it gained a phase.
    ADD COLUMN phase          VARCHAR(32)  NULL AFTER status,

    -- The Langfuse trace, so the console can deep-link from a run to the
    -- reasoning that produced it.
    ADD COLUMN trace_id       VARCHAR(128) NULL AFTER vendor,

    -- What the runtime's saved state was written by. Read before resuming: a
    -- run parked on Friday can come back to a deployment that happened on
    -- Saturday, and a half-understood transcript is how an agent repeats a
    -- destructive tool call it has already made.
    ADD COLUMN state_version  INT          NULL AFTER transcript,

    -- The outstanding tool calls of the current turn, and the results collected
    -- so far. Both NULL except between a CALL_TOOLS directive and the moment
    -- every call in it has been answered.
    --
    -- Vendors require every tool call in a turn to be answered together, so a
    -- turn cannot be sent back half-finished. These two columns are what let a
    -- run park mid-turn on an approval and pick the rest up days later without
    -- re-running anything.
    ADD COLUMN pending_calls   MEDIUMTEXT NULL AFTER pending_tool_id,
    ADD COLUMN pending_results MEDIUMTEXT NULL AFTER pending_calls,

    -- Claims the report could not substantiate. Stored rather than derived so
    -- the run view can flag a report without re-parsing it, and so "how often
    -- do our agents assert things they did not observe" is a query rather than
    -- a research project.
    ADD COLUMN uncited_claims  TEXT       NULL AFTER error;

-- Runs whose report shipped unverified. Small and highly selective — almost
-- every row is NULL — so this is the index that makes the quality question
-- cheap to ask.
CREATE INDEX ix_agent_runs_uncited ON agent_runs ((uncited_claims IS NOT NULL));
