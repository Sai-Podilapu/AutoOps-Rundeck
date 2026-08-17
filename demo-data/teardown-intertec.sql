-- ===================================================================
-- REMOVE THE DEMO SEED
-- Deletes only rows created by seed-intertec.sql (id >= 9000 AND
-- created_by / tenant scoped). Touches nothing else in the tenant.
--
--   docker compose exec -T mysql mysql -uroot -prootpass \
--     < demo-data/teardown-intertec.sql
-- ===================================================================

USE autoops_agent;
DELETE FROM agents
 WHERE tenant_id = 'intertec-systems-0c600f88' AND created_by = 'demo-seed' AND id >= 9000;

USE autoops_workflow;
DELETE FROM workflows
 WHERE tenant_id = 'intertec-systems-0c600f88' AND created_by = 'demo-seed' AND id >= 9000;

USE autoops_core;
DELETE FROM runs
 WHERE tenant_id = 'intertec-systems-0c600f88' AND project_id = 9001 AND id >= 9000;
DELETE FROM jobs
 WHERE tenant_id = 'intertec-systems-0c600f88' AND created_by = 'demo-seed' AND id >= 9000;
DELETE FROM projects
 WHERE tenant_id = 'intertec-systems-0c600f88' AND created_by = 'demo-seed' AND id = 9001;
