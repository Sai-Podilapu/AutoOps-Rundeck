-- Remove the sample catalog items V16 seeds.
--
-- Those eight rows (5 scripts, 2 workflows, 1 agent — "Disk & memory health
-- check", "Kubernetes rolling restart", "Uptime agent sweep" and the rest)
-- were placeholder content to make an empty console look alive. The platform
-- catalog is the PROVIDER's real product surface now, so shipped samples are
-- indistinguishable from things a customer is meant to import and run.
--
-- Scoped by created_by = 'autoops', which is what V16 stamps on its seed rows
-- and nothing else uses: real catalog items carry the operator's own address
-- (admin@autoops.com and so on). Deleting by id would be wrong — ids differ
-- per environment.
--
-- V16 itself is left alone deliberately: it is an applied migration, and
-- editing one breaks Flyway's checksum and stops the service booting. Doing it
-- forward means a fresh database still gets the inserts, then this removes
-- them, so every environment lands in the same place.
--
-- Nothing references these rows (no tenant copy, workflow or agent carries a
-- source_id in that set), so the delete cannot orphan a customer's artefact —
-- and it deliberately does NOT touch catalog items authored by an operator,
-- which include the customer-facing demo content.
DELETE FROM library_items
 WHERE tenant_id IS NULL
   AND created_by = 'autoops';
