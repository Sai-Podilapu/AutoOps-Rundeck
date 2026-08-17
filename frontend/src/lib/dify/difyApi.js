/**
 * The Dify surface of the AutoOps API.
 *
 * Every call here targets core-service at `/api/dify/**` — the browser never
 * talks to Dify directly, because the app key and the console session both
 * grant far more than an end user should hold.
 *
 * This module serves NO fixtures. Until core-service exposes `/api/dify/**`,
 * these calls fail and the screens above them render their empty/error state.
 * That is deliberate: an operator must never be shown a model provider,
 * dataset or run that does not exist. Nothing here fabricates data.
 */

import { realFetch, ApiError, tokenStore } from "../api";

const call = (path, opts) => realFetch(`/dify${path}`, { auth: true, ...opts });

export const difyApi = {
  // ---- apps --------------------------------------------------------------
  listApps: () => call("/apps"),

  getApp: (appId) => call(`/apps/${appId}`),

  createApp: (body) => call("/apps", { method: "POST", body }),

  deleteApp: (appId) => call(`/apps/${appId}`, { method: "DELETE" }),

  // ---- draft graph (what the designer edits) ------------------------------
  getDraft: (appId) => call(`/apps/${appId}/draft`),

  saveDraft: (appId, draft) => call(`/apps/${appId}/draft`, { method: "PUT", body: draft }),

  /** Publishes the draft — this is what makes the Service API serve the app. */
  publish: (appId) => call(`/apps/${appId}/publish`, { method: "POST" }),

  /** Generates and returns the Dify DSL YAML without importing it. */
  exportDsl: (appId) => call(`/apps/${appId}/dsl`),

  /**
   * The workflows this platform holds a Service API key for — i.e. the ones
   * that can actually be published to the catalog and run.
   *
   * NOT the same as listApps(): that lists everything in the Dify workspace,
   * including drafts that were never published and apps whose app- key was
   * never configured here. Publishing one of those would produce a catalog
   * entry that fails at run time.
   */
  runnableCatalog: () => call("/catalog"),

  // ---- model providers ----------------------------------------------------
  listProviders: () => call("/model-providers"),

  listModels: (provider, modelType) =>
    call(
      `/model-providers/${encodeURIComponent(provider)}/models${modelType ? `?type=${modelType}` : ""}`,
    ),

  /** Every configured model across providers — what the model picker lists. */
  listAvailableModels: (modelType = "llm") => call(`/models?type=${modelType}`),

  saveProviderCredentials: (provider, credentials) =>
    call(`/model-providers/${encodeURIComponent(provider)}/credentials`, {
      method: "POST",
      body: { credentials },
    }),

  removeProviderCredentials: (provider) =>
    call(`/model-providers/${encodeURIComponent(provider)}/credentials`, { method: "DELETE" }),

  getDefaultModels: () => call("/workspace/default-models"),

  setDefaultModel: (modelType, provider, model) =>
    call("/workspace/default-models", {
      method: "POST",
      body: { model_type: modelType, provider, model },
    }),

  // ---- plugins / marketplace ---------------------------------------------
  listMarketplace: (q = "") => call(`/plugins/marketplace?q=${encodeURIComponent(q)}`),

  installPlugin: (pluginId) =>
    call("/plugins/install", { method: "POST", body: { plugin_id: pluginId } }),

  uninstallPlugin: (pluginId) =>
    call("/plugins/uninstall", { method: "POST", body: { plugin_id: pluginId } }),

  // ---- tools + knowledge --------------------------------------------------
  listToolProviders: () => call("/tool-providers"),
  listDatasets: () => call("/datasets"),

  // ---- runs ---------------------------------------------------------------
  run: (appId, inputs) => call(`/apps/${appId}/run`, { method: "POST", body: { inputs } }),

  getRun: (runId) => call(`/runs/${runId}`),

  stopRun: (taskId) => call(`/runs/${taskId}/stop`, { method: "POST" }),

  listRunLogs: (appId) => call(`/apps/${appId}/logs`),
};

/** A fresh workflow: just a Start node, matching Dify's own new-app canvas. */
export function emptyDraft() {
  return {
    graph: {
      nodes: [
        {
          id: "start",
          type: "start",
          position: { x: 80, y: 200 },
          data: { title: "Start", type: "start", desc: "", variables: [] },
        },
      ],
      edges: [],
      viewport: { x: 0, y: 0, zoom: 0.9 },
    },
    features: {},
    environment_variables: [],
    conversation_variables: [],
  };
}

/**
 * Streams a draft/published run.
 *
 * EventSource cannot carry an Authorization header, so the SSE bridge is a
 * fetch + ReadableStream reader instead — same token handling as realFetch.
 * `onEvent` receives each parsed Dify event ({event, data}).
 */
export async function streamRun(appId, inputs, onEvent, { signal, draft = false } = {}) {
  const res = await fetch(
    `${import.meta.env.VITE_API_URL || "/api"}/dify/apps/${appId}/${draft ? "draft-run" : "run"}`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(tokenStore.access ? { Authorization: `Bearer ${tokenStore.access}` } : {}),
      },
      body: JSON.stringify({ inputs }),
      signal,
    },
  );
  if (!res.ok || !res.body) {
    throw new ApiError(`Run failed (${res.status})`, res.status, null);
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    // SSE frames are separated by a blank line; a frame may arrive split.
    const frames = buffer.split("\n\n");
    buffer = frames.pop() || "";
    for (const frame of frames) {
      const line = frame.split("\n").find((l) => l.startsWith("data:"));
      if (!line) continue;
      try {
        onEvent(JSON.parse(line.slice(5).trim()));
      } catch {
        /* ping frames and partial JSON are expected — skip */
      }
    }
  }
}