-- ============================================================
-- VIEWER: read-only workspace member. Until now the members page offered
-- Admin/Operator/Viewer but only ADMIN and CLIENT existed, so "Viewer" was
-- silently stored as CLIENT and read back as "Operator". Type policy:
-- extending an ENUM = ALTER ... MODIFY + Java enum constant.
-- ============================================================

ALTER TABLE users MODIFY COLUMN role
    ENUM('PROVIDER','CLIENT','ADMIN','VIEWER') NOT NULL;
