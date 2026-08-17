-- ============================================================
-- Notifications (tenant-wide inbox, per-user read tracking) and Nodes
-- (project-scoped registry of execution targets). Notifications are written
-- by the platform (run failures, approval lifecycle); read state is per
-- member, so it lives in a join table instead of a flag on the row.
-- ============================================================

CREATE TABLE notifications (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id   VARCHAR(64)     NOT NULL,
    kind        ENUM('SYSTEM','ALERT','PROVIDER') NOT NULL,
    title       VARCHAR(255)    NOT NULL,
    body        VARCHAR(1024)   NULL,
    link        VARCHAR(255)    NULL,          -- SPA route the card opens
    created_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_notifications_tenant (tenant_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE notification_reads (
    notification_id BIGINT UNSIGNED NOT NULL,
    reader          VARCHAR(255)    NOT NULL,  -- JWT subject (email)
    read_at         TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (notification_id, reader),
    CONSTRAINT fk_nr_notification FOREIGN KEY (notification_id)
        REFERENCES notifications (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE nodes (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id   VARCHAR(64)     NOT NULL,
    project_id  BIGINT UNSIGNED NOT NULL,
    name        VARCHAR(128)    NOT NULL,
    type        ENUM('RUNNER','CONTAINER','VM','SERVERLESS') NOT NULL DEFAULT 'RUNNER',
    region      VARCHAR(64)     NULL,
    created_by  VARCHAR(255)    NULL,
    created_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_nodes_tenant_project (tenant_id, project_id),
    CONSTRAINT fk_nodes_project FOREIGN KEY (project_id)
        REFERENCES projects (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
