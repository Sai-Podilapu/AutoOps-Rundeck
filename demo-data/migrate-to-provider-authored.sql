-- ===================================================================
-- Convert the Intertec demo set to the provider-authored model.
--
-- Before: 7 workflows and 2 agents authored INSIDE the Intertec workspace.
-- After:  the same 7 + 2, published as platform catalog items owned by the
--         provider and rolled out to Intertec — identical to what the console
--         produces today, so the demo story is unchanged and now also shows
--         the rollout model itself.
--
-- Run history, schedules, run counts and ids are all untouched: the rows stay
-- where they are and only gain origin + source_id. Nothing is re-created, so
-- the NEFT-failure → exception-repair thread still holds together.
--
-- Idempotent: re-running matches on title and skips what it already did.
-- ===================================================================

SET @tenant := 'intertec-systems-1542f8a3';
SET @provider := 'admin@autoops.com';

-- ---- 1. Publish each demo workflow into the platform catalog ----
-- category lives inside the canvas JSON, so it is lifted out here rather than
-- defaulted to 'General'.
INSERT INTO autoops_core.library_items
    (tenant_id, title, description, type, category, premium, definition, installs, created_by)
SELECT NULL,
       w.name,
       CONCAT('Provider-managed automation (', w.node_count, ' nodes).'),
       'WORKFLOW',
       COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(w.definition, '$.category')), 'null'), 'General'),
       0,
       w.definition,
       1,
       @provider
FROM autoops_workflow.workflows w
WHERE w.tenant_id = @tenant
  AND w.created_by = 'demo-seed'
  AND NOT EXISTS (SELECT 1 FROM autoops_core.library_items l
                  WHERE l.tenant_id IS NULL AND l.title = w.name AND l.type = 'WORKFLOW');

-- ---- 2. Publish each demo agent ----
-- An agent's catalog spec carries the persona and the allow-list; `nodes` is
-- present and empty because LibraryService requires a steps[] or nodes[] key.
INSERT INTO autoops_core.library_items
    (tenant_id, title, description, type, category, premium, definition, installs, created_by)
SELECT NULL,
       a.name,
       a.description,
       'AGENT',
       'Ops',
       0,
       JSON_OBJECT(
           'nodes', JSON_ARRAY(),
           'description', a.description,
           'model', a.model,
           'instructions', a.instructions,
           -- Empty, deliberately. The demo agents' `tools` column holds
           -- DISPLAY NAMES ("Runbook knowledge base"), not allow-list entries
           -- — and an allow-list names jobs and workflows by id, which are
           -- per-customer and do not exist at catalog time. A catalog agent
           -- therefore ships able to operate nothing; tools are granted per
           -- customer after delivery. The already-delivered Intertec copies
           -- keep the tools they have.
           'tools', JSON_ARRAY()
       ),
       1,
       @provider
FROM autoops_agent.agents a
WHERE a.tenant_id = @tenant
  AND a.created_by = 'demo-seed'
  AND NOT EXISTS (SELECT 1 FROM autoops_core.library_items l
                  WHERE l.tenant_id IS NULL AND l.title = a.name AND l.type = 'AGENT');

-- ---- 3. Seal the delivered copies ----
-- origin=PROVIDER is what makes workflow-service/agent-service withhold the
-- definition from Intertec; source_id links each copy back to its catalog row.
UPDATE autoops_workflow.workflows w
JOIN autoops_core.library_items l
  ON l.tenant_id IS NULL AND l.type = 'WORKFLOW' AND l.title = w.name
SET w.origin = 'PROVIDER', w.source_id = l.id
WHERE w.tenant_id = @tenant AND w.created_by = 'demo-seed';

UPDATE autoops_agent.agents a
JOIN autoops_core.library_items l
  ON l.tenant_id IS NULL AND l.type = 'AGENT' AND l.title = a.name
SET a.origin = 'PROVIDER', a.source_id = l.id
WHERE a.tenant_id = @tenant AND a.created_by = 'demo-seed';
