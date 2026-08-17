-- One delivered copy of a catalog workflow per project.
--
-- WorkflowService#rollOut refuses a repeat delivery, but a service-level check
-- only holds for callers that come through it. This is the backstop: the
-- /internal rollout endpoint is reachable by anything holding the internal
-- token, and two concurrent rollouts of the same item would both pass the
-- exists() check before either committed.
--
-- (project_id, source_id), NOT (tenant_id, source_id): delivering the same
-- workflow into two of a customer's projects is a legitimate rollout. Two
-- copies in ONE project is the defect.
--
-- Tenant-built workflows are unaffected: their source_id is NULL, and MySQL
-- permits any number of NULLs in a UNIQUE index.

-- Existing duplicates would make CREATE UNIQUE INDEX fail and stop the service
-- booting. Keep the earliest delivery of each pair and drop the rest — the
-- later row is the accident, and the earlier one is what run history already
-- points at.
DELETE later FROM workflows later
  JOIN (SELECT project_id, source_id, MIN(id) AS keep_id
          FROM workflows
         WHERE source_id IS NOT NULL
         GROUP BY project_id, source_id
        HAVING COUNT(*) > 1) dupe
    ON later.project_id = dupe.project_id
   AND later.source_id = dupe.source_id
 WHERE later.id > dupe.keep_id;

CREATE UNIQUE INDEX uq_workflows_project_source ON workflows (project_id, source_id);
