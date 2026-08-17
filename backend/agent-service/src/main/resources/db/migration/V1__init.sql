-- ============================================================
-- agent-service owns AI agents.
--
-- Same table core-service briefly held (its V22), moved here whole so an
-- existing deployment can copy rows across unchanged:
--
--   INSERT INTO autoops_agent.agents SELECT * FROM autoops_core.agents;
--
-- An agent is CONFIGURATION, not a runner. It carries the persona
-- (instructions) and — this is the part that matters for safety — the
-- explicit list of automations it is allowed to operate (`tools`).
--
-- The allow-list is a closed set: an agent can never reach a job or a
-- workflow that is not named here. What the split changed is WHO answers the
-- question: jobs are verified against core-service and workflows against
-- workflow-service, both over their /internal APIs, on every write. There is
-- no foreign key left to fall back on, so AgentService refuses the write
-- when either service cannot confirm the target.
--
-- tool_count stays derived server-side from `tools` — a client-supplied
-- count would be a way around that validation.
--
-- Agents count toward the plan's MAX_AUTOMATIONS alongside workflows; the
-- workflow half of that budget is fetched from workflow-service.
-- ============================================================

CREATE TABLE agents (
    id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id    VARCHAR(64)     NOT NULL,
    project_id   BIGINT UNSIGNED NOT NULL,  -- core-service project, no FK across DBs
    name         VARCHAR(128)    NOT NULL,
    description  VARCHAR(512)    NULL,
    -- Model id the agent will run on (e.g. "gpt-4o"). Free text on purpose:
    -- no model runtime is wired yet, so nothing may pretend to validate it.
    model        VARCHAR(128)    NULL,
    instructions MEDIUMTEXT      NULL,          -- system prompt / operating brief
    tools        MEDIUMTEXT      NULL,          -- JSON [{"type":"JOB|WORKFLOW","id":N}]
    tool_count   INT UNSIGNED    NOT NULL DEFAULT 0,  -- derived from `tools`
    enabled      TINYINT(1)      NOT NULL DEFAULT 1,
    created_by   VARCHAR(255)    NULL,
    created_at   TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at   TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                 ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_agents_project_name (project_id, name),
    KEY idx_agents_tenant (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
