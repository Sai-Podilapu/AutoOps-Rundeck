-- A workspace picks its models per PURPOSE, not one model for everything.
-- default_model is the chat model an agent talks to; retrieval needs an
-- embedding model, which is a different model from a different family and
-- cannot be the same value. Nullable: most vendors have one, Anthropic
-- publishes none, and a workspace that does no retrieval needs neither.
ALTER TABLE model_providers
    ADD COLUMN default_embedding_model VARCHAR(128) NULL AFTER default_model;
