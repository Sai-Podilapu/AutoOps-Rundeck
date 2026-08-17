/**
 * Model SDKs — the vendors' own Java clients, one folder per vendor.
 *
 * <pre>
 *   modelsdk/
 *     ModelVendor       which vendors exist, and which SDK serves each
 *     ModelCredentials  the decrypted config map, read the same way by all
 *     openai/           OpenAI + Mistral, Groq, DeepSeek, xAI, Ollama
 *     claude/           Anthropic (ModelVendor.ANTHROPIC)
 *     google/           Gemini
 *     azure/            Azure OpenAI
 *     bedrock/          AWS Bedrock
 *     huawei/           Pangu / ModelArts
 * </pre>
 *
 * <p>One folder per vendor because the awkwardness is per vendor: Bedrock must
 * refuse the ambient AWS role, Azure routes on a deployment name, Huawei needs
 * a project id, Ollama has no secret. Kept in a single file those exceptions
 * read as noise; kept apart, each sits next to the explanation of why it is
 * there, and a fix touches one file.
 *
 * <p>Each factory returns the VENDOR'S own client type rather than a shared
 * interface. Those types have nothing in common — Bedrock takes bytes,
 * ModelArts takes a deployment id — and the adapter that flattens them belongs
 * to the agent runtime, which is not built yet. Writing the interface first
 * would bake in guesses about a loop that does not exist.
 *
 * <p>Credentials never live here. Core-service stores them AES-GCM encrypted
 * and decrypts them for the length of one call; this package turns one such
 * map into a configured client and holds nothing.
 */
package com.intertec.autoops.agent.modelsdk;
