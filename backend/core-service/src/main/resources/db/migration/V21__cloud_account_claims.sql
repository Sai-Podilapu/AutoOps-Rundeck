-- ============================================================
-- One cloud account, one tenant.
--
-- A cloud account — and the credential material that authenticates to it —
-- may be linked to exactly ONE AutoOps tenant. If AWS account 123456789012
-- is connected by tenant A, tenant B cannot connect it, not even with a
-- different key pair. This is the containment for LEAKED CREDENTIALS: a
-- stolen key cannot be replayed into an attacker's own tenant, where it would
-- otherwise be a fully-functional automation runtime pointed at the victim's
-- infrastructure.
--
-- Rows are keyed by a KEYED HASH (HMAC-SHA256 under CLOUD_CRED_KEY) of the
-- identifying value, never by the value itself: a 12-digit AWS account number
-- is trivially brute-forced from a plain SHA-256, and this table must not
-- become a readable inventory of customer account numbers and access key ids.
--
-- kind = ACCOUNT     the account the credentials point AT (AWS account number,
--                    Azure subscription, GCP project, Entra tenant, OCI
--                    tenancy, public cluster endpoint)
--        CREDENTIAL  the authenticating material itself (access key id,
--                    service principal, service-account key, kubeconfig) —
--                    this one catches a leak before anything is verified
--
-- Ownership is per TENANT, not per connection: one tenant may legitimately
-- hold the same account on several connections (one AWS account, two IAM
-- users, one connection per project). connection_id records which connection
-- first claimed it, for support. The claim is released when the tenant's last
-- connection holding it is disconnected or re-keyed.
-- ============================================================

CREATE TABLE cloud_account_claims (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    platform      ENUM('AWS','AZURE','GCP','HUAWEI','ORACLE','M365','KUBERNETES') NOT NULL,
    kind          ENUM('ACCOUNT','CREDENTIAL') NOT NULL,
    fingerprint   CHAR(64)        NOT NULL,
    tenant_id     VARCHAR(64)     NOT NULL,
    connection_id BIGINT UNSIGNED NULL,
    created_at    TIMESTAMP(6)    NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- The rule itself. Enforced by the DATABASE so two tenants racing to
    -- connect the same account cannot both win.
    UNIQUE KEY uq_cloud_account_claim (platform, kind, fingerprint),
    KEY idx_cloud_claim_tenant (tenant_id),
    KEY idx_cloud_claim_connection (connection_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- Existing connections are claimed by a reconciliation pass at startup
-- (CloudAccountRegistry#reconcileAll) — the fingerprints need the credential
-- key, so they cannot be computed in SQL. Oldest connection wins a contested
-- account.

ALTER TABLE core_audit_log
    MODIFY event_type ENUM('PROJECT_CREATED','PROJECT_UPDATED','PROJECT_ARCHIVED','PROJECT_RESTORED',
                      'WORKFLOW_CREATED','WORKFLOW_UPDATED','WORKFLOW_DELETED',
                      'WORKFLOW_ENABLED','WORKFLOW_DISABLED',
                      'JOB_CREATED','JOB_UPDATED','JOB_DELETED',
                      'RUN_TRIGGERED','RUN_CANCELED',
                      'APPROVAL_REQUESTED','APPROVAL_APPROVED','APPROVAL_REJECTED',
                      'CONNECTION_CREATED','CONNECTION_CREDENTIALS_UPDATED',
                      'CONNECTION_VERIFIED','CONNECTION_DISCONNECTED','CONNECTION_ASSIGNED',
                      'CONNECTION_CLAIM_REJECTED','CONNECTION_QUARANTINED',
                      'SCM_CONFIGURED','SCM_EXPORTED','SCM_IMPORTED',
                      'APPROVAL_SETTINGS_UPDATED','GOVERNANCE_POLICY_UPDATED',
                      'COMPLIANCE_REPORT_GENERATED',
                      'SECRET_CREATED','SECRET_UPDATED','SECRET_DELETED',
                      'WEBHOOK_CREATED','WEBHOOK_UPDATED','WEBHOOK_DELETED',
                      'COMMAND_DISPATCHED',
                      'CONNECTOR_CREATED','CONNECTOR_DELETED',
                      'LIBRARY_CREATED','LIBRARY_CLONED',
                      'BROADCAST_SENT') NOT NULL;