-- ============================================================
-- Approval gate extended to workflows. Approvals become target-typed
-- (JOB | WORKFLOW) like runs; job_id/job_name generalize to
-- target_id/target_name. Workflows are gated AUTOMATICALLY when complex
-- (>= 5 nodes or any terraform/kubernetes/awslambda/azurefn/ssh node) —
-- there is no per-workflow toggle; simple workflows never queue approvals.
-- ============================================================

ALTER TABLE approvals
    ADD COLUMN target_type ENUM('JOB','WORKFLOW') NOT NULL DEFAULT 'JOB' AFTER project_id,
    RENAME COLUMN job_id TO target_id,
    RENAME COLUMN job_name TO target_name;