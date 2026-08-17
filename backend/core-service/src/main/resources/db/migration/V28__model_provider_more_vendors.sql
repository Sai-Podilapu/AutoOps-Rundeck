-- Four more vendors a workspace can bring its own key for.
--
-- MODIFY rather than a lookup table, to stay consistent with how this column
-- has always been defined; the enum is closed on purpose, because a kind with
-- no entry in ModelProviderCatalog has no credential shape and no way to be
-- probed. Appending values is safe — MySQL stores the ordinal, and every
-- existing row keeps the value it had.
ALTER TABLE model_providers
    MODIFY COLUMN kind ENUM('OPENAI','ANTHROPIC','GOOGLE','AZURE_OPENAI','BEDROCK',
                            'HUAWEI','MISTRAL','GROQ','DEEPSEEK','XAI','OLLAMA',
                            'ELEVENLABS','SAGEMAKER','OPENROUTER','HUGGINGFACE') NOT NULL;
