-- ============================================================
-- Identity the PROVIDER reported at the last successful verification: the
-- AWS account number + IAM caller, the Azure subscription id + display name,
-- the GCP project, the Entra tenant + organization, the cluster URL +
-- context. Credentials only ever contain what the user typed; these are the
-- provider's own answer, so they are stored rather than re-derived.
-- Cleared on disconnect along with the rest of the verification state.
-- ============================================================

ALTER TABLE cloud_connections
    ADD COLUMN verified_account_id   VARCHAR(128) NULL AFTER last_verified_message,
    ADD COLUMN verified_account_name VARCHAR(256) NULL AFTER verified_account_id;
