/**
 * Where a third party's logo lives — model vendors and notification channels.
 *
 * One map per surface, in one file, because the failure mode is silent: a slug
 * that does not match the file on disk renders the generic fallback glyph and
 * looks like "no logo supplied" rather than a typo. That has now happened
 * three times (Teams' plugin key is `microsoft-teams`, SageMaker's file is
 * capitalised, Hugging Face's is hyphenated), which is why `brandLogos.test.js`
 * checks every path here against the filesystem.
 *
 * Keys are the identifiers the BACKEND sends — a provider kind, a plugin key —
 * never a display name.
 */

/**
 * The kind names the vendor; the file names the BRAND, and the two differ
 * often enough to need writing down — ANTHROPIC ships Claude, GOOGLE ships
 * Gemini, XAI ships Grok.
 */
export const VENDOR_LOGO = {
  OPENAI: "openai",
  ANTHROPIC: "claude",
  GOOGLE: "gemini",
  AZURE_OPENAI: "azure-openai",
  BEDROCK: "bedrock",
  HUAWEI: "huawei",
  MISTRAL: "mistral",
  GROQ: "groq",
  DEEPSEEK: "deepseek",
  XAI: "grok",
  OLLAMA: "ollama",
  // Exactly as the files are named: nginx serves case-sensitively, so
  // "sagemaker" would 404 against SageMaker.png and fall back to a glyph.
  OPENROUTER: "open-router",
  HUGGINGFACE: "hugging-face",
  ELEVENLABS: "elevenlabs",
  SAGEMAKER: "SageMaker",
};

/**
 * Keyed by the plugin key plugin-service reports — NOT the provider's common
 * name. Teams is where those differ: its descriptor key is "microsoft-teams",
 * so an entry under "teams" falls through to the glyph while looking correct.
 */
export const CHANNEL_LOGO = {
  slack: "slack",
  "microsoft-teams": "microsoft-teams",
  gmail: "gmail",
  outlook: "outlook",
  webhook: "webhook",
  github: "Github",
};

export const vendorLogo = (kind) =>
  VENDOR_LOGO[kind] ? `/assets/models/${VENDOR_LOGO[kind]}.png` : null;

export const channelLogo = (pluginKey) =>
  CHANNEL_LOGO[pluginKey] ? `/assets/alerts/${CHANNEL_LOGO[pluginKey]}.png` : null;
