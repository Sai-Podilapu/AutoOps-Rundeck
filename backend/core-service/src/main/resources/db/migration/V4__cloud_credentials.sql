-- ============================================================
-- Cloud integrations become executable: connections can now hold the
-- credentials terraform/kubernetes steps need. Credentials are stored
-- AES-GCM-encrypted (CLOUD_CRED_KEY) and are never returned by the API.
-- KUBERNETES joins the platform catalog (kubeconfig-based clusters).
-- ============================================================

ALTER TABLE cloud_connections
    MODIFY COLUMN platform ENUM('AWS','AZURE','GCP','HUAWEI','ORACLE','M365','KUBERNETES') NOT NULL,
    ADD COLUMN credentials_enc TEXT NULL AFTER status;
