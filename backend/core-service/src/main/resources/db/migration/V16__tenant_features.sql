-- ============================================================
-- Production backends for the last mock tenant surfaces:
--   secrets    — encrypted key/value vault (values never returned)
--   webhooks   — INBOUND trigger URLs: POST /api/hooks/{token} starts a job
--   library    — template catalog (tenant_id NULL = platform-managed) + seeds
--   commands   — ad-hoc command dispatch history (runs on the platform runner)
--   connectors — third-party plugins (Slack/GitHub/webhook) w/ real tests
-- Plus: WEBHOOK run trigger, and audit ENUM values for all of the above.
-- ============================================================

CREATE TABLE secrets (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id   VARCHAR(64)     NOT NULL,
    path        VARCHAR(255)    NOT NULL,
    type        ENUM('OPAQUE','TLS','SSH') NOT NULL DEFAULT 'OPAQUE',
    value_enc   TEXT            NOT NULL,      -- AES-GCM; never returned by the API
    created_by  VARCHAR(255)    NULL,
    created_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
                                ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_secrets_tenant_path (tenant_id, path)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE webhooks (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id     VARCHAR(64)     NOT NULL,
    project_id    BIGINT UNSIGNED NOT NULL,
    name          VARCHAR(128)    NOT NULL,
    token         CHAR(43)        NOT NULL,     -- urlsafe random; the trigger credential
    target_type   ENUM('JOB','WORKFLOW') NOT NULL DEFAULT 'JOB',
    target_id     BIGINT UNSIGNED NOT NULL,
    enabled       TINYINT(1)      NOT NULL DEFAULT 1,
    last_fired_at TIMESTAMP(6)    NULL,
    last_status   VARCHAR(32)     NULL,         -- accepted | denied:<reason>
    created_by    VARCHAR(255)    NULL,
    created_at    TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uq_webhooks_token (token),
    KEY idx_webhooks_tenant_project (tenant_id, project_id),
    CONSTRAINT fk_webhooks_project FOREIGN KEY (project_id)
        REFERENCES projects (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

ALTER TABLE runs
    MODIFY trigger_type ENUM('MANUAL','SCHEDULE','WEBHOOK') NOT NULL;

CREATE TABLE library_items (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id   VARCHAR(64)     NULL,           -- NULL = platform-managed catalog
    title       VARCHAR(128)    NOT NULL,
    description VARCHAR(512)    NULL,
    type        ENUM('SCRIPT','WORKFLOW','AGENT') NOT NULL DEFAULT 'SCRIPT',
    category    VARCHAR(64)     NOT NULL DEFAULT 'General',
    premium     TINYINT(1)      NOT NULL DEFAULT 0,
    definition  MEDIUMTEXT      NOT NULL,       -- runnable job/workflow definition JSON
    installs    INT UNSIGNED    NOT NULL DEFAULT 0,
    source_id   BIGINT UNSIGNED NULL,           -- catalog item this was cloned from
    created_by  VARCHAR(255)    NULL,
    created_at  TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_library_tenant (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE commands (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id     VARCHAR(64)     NOT NULL,
    command       VARCHAR(512)    NOT NULL,
    target        VARCHAR(64)     NOT NULL DEFAULT 'platform-runner',
    dispatched_by VARCHAR(255)    NULL,
    status        ENUM('SUCCEEDED','FAILED') NOT NULL,
    output        MEDIUMTEXT      NULL,
    duration_ms   BIGINT UNSIGNED NULL,
    created_at    TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_commands_tenant (tenant_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE connectors (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    tenant_id     VARCHAR(64)     NOT NULL,
    kind          ENUM('SLACK_WEBHOOK','GENERIC_WEBHOOK','GITHUB') NOT NULL,
    name          VARCHAR(128)    NOT NULL,
    config_enc    TEXT            NULL,          -- AES-GCM {url} or {token,repo}
    last_test_ok  TINYINT(1)      NULL,          -- null = never tested
    last_test_at  TIMESTAMP(6)    NULL,
    created_by    VARCHAR(255)    NULL,
    created_at    TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_connectors_tenant (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

ALTER TABLE core_audit_log
    MODIFY event_type ENUM('PROJECT_CREATED','PROJECT_UPDATED','PROJECT_ARCHIVED','PROJECT_RESTORED',
                      'WORKFLOW_CREATED','WORKFLOW_UPDATED','WORKFLOW_DELETED',
                      'WORKFLOW_ENABLED','WORKFLOW_DISABLED',
                      'JOB_CREATED','JOB_UPDATED','JOB_DELETED',
                      'RUN_TRIGGERED','RUN_CANCELED',
                      'APPROVAL_REQUESTED','APPROVAL_APPROVED','APPROVAL_REJECTED',
                      'CONNECTION_CREATED','CONNECTION_CREDENTIALS_UPDATED',
                      'CONNECTION_VERIFIED','CONNECTION_DISCONNECTED',
                      'SCM_CONFIGURED','SCM_EXPORTED','SCM_IMPORTED',
                      'APPROVAL_SETTINGS_UPDATED','GOVERNANCE_POLICY_UPDATED',
                      'COMPLIANCE_REPORT_GENERATED',
                      'SECRET_CREATED','SECRET_UPDATED','SECRET_DELETED',
                      'WEBHOOK_CREATED','WEBHOOK_UPDATED','WEBHOOK_DELETED',
                      'COMMAND_DISPATCHED',
                      'CONNECTOR_CREATED','CONNECTOR_DELETED',
                      'LIBRARY_CREATED','LIBRARY_CLONED',
                      'BROADCAST_SENT') NOT NULL;

-- ------------------------------------------------------------
-- Platform template catalog seed — every definition is RUNNABLE with the
-- executors that exist today (command/script/pyscript/rest/terraform/k8s).
-- ------------------------------------------------------------
INSERT INTO library_items (tenant_id, title, description, type, category, premium, definition, created_by) VALUES
  (NULL, 'Disk & memory health check',
   'One-step host health snapshot: disk usage, memory, and load average in the run log.',
   'SCRIPT', 'Maintenance', 0,
   '{"steps":[{"id":"script","label":"Host health snapshot","value":"df -h\\nfree -m || vm_stat\\nuptime"}]}', 'autoops'),
  (NULL, 'Service restart with verification',
   'Restarts a systemd service and verifies it came back before succeeding.',
   'SCRIPT', 'Maintenance', 0,
   '{"steps":[{"id":"command","label":"Restart service","value":"systemctl restart myservice"},{"id":"command","label":"Verify it is active","value":"systemctl is-active myservice"}]}', 'autoops'),
  (NULL, 'HTTP endpoint monitor',
   'Calls a health endpoint and fails the run when it does not answer 2xx — pair with a schedule for basic uptime monitoring.',
   'SCRIPT', 'Monitoring', 0,
   '{"steps":[{"id":"rest","label":"Probe endpoint","value":"GET https://example.com/health","retries":2}]}', 'autoops'),
  (NULL, 'Log cleanup (Python)',
   'Deletes rotated logs older than 14 days from /var/log — adjust the path and age to taste.',
   'SCRIPT', 'Maintenance', 0,
   '{"steps":[{"id":"pyscript","label":"Prune old logs","value":"import os, time\\nroot=''/var/log''\\ncutoff=time.time()-14*86400\\nfor dirpath,_,files in os.walk(root):\\n    for f in files:\\n        p=os.path.join(dirpath,f)\\n        if f.endswith(''.gz'') and os.path.getmtime(p)<cutoff:\\n            os.remove(p); print(''removed'',p)"}]}', 'autoops'),
  (NULL, 'Nightly database backup',
   'Dumps a MySQL database to a dated file and prunes backups older than 7 days. Schedule it nightly.',
   'SCRIPT', 'Data', 0,
   '{"steps":[{"id":"script","label":"Dump database","value":"mysqldump -h $DB_HOST -u $DB_USER -p$DB_PASSWORD mydb > /backups/mydb-$(date +%F).sql"},{"id":"command","label":"Prune old backups","value":"find /backups -name ''mydb-*.sql'' -mtime +7 -delete","continueOnError":true}]}', 'autoops'),
  (NULL, 'Kubernetes rolling restart',
   'Rolling-restarts a deployment and waits for rollout to finish. Needs a KUBERNETES integration.',
   'WORKFLOW', 'Kubernetes', 1,
   '{"nodes":[{"id":"kubernetes","label":"Rolling restart","value":"rollout restart deployment/my-app -n production"},{"id":"kubernetes","label":"Wait for rollout","value":"rollout status deployment/my-app -n production"}]}', 'autoops'),
  (NULL, 'Terraform S3 static site',
   'Provisions an S3 bucket configured for static website hosting. Needs an AWS integration; runs plan first.',
   'WORKFLOW', 'Cloud', 1,
   '{"nodes":[{"id":"terraform","label":"Provision bucket","action":"apply","value":"resource \\"aws_s3_bucket\\" \\"site\\" {\\n  bucket = \\"my-autoops-site\\"\\n}\\nresource \\"aws_s3_bucket_website_configuration\\" \\"site\\" {\\n  bucket = aws_s3_bucket.site.id\\n  index_document { suffix = \\"index.html\\" }\\n}"}]}', 'autoops'),
  (NULL, 'Uptime agent sweep',
   'Agent command that reports uptime and kernel version from the runner — a template for fleet-wide facts gathering.',
   'AGENT', 'Monitoring', 0,
   '{"steps":[{"id":"agent","label":"Report uptime","value":"uptime && uname -a"}]}', 'autoops');
