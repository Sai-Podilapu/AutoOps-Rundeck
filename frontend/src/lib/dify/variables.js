/**
 * Dify's variable reference system.
 *
 * Dify addresses a value by a *selector* — an array like `["1712…", "text"]`
 * meaning "the `text` output of node 1712…". Structured config fields store the
 * selector array; free-text fields (prompts, templates, answers) embed the same
 * thing as `{{#1712….text#}}`. Both forms round-trip through here.
 *
 * The rule that makes this non-trivial: a node may only reference variables
 * from nodes *upstream* of it. `availableVariables()` walks the edge graph
 * backwards so the picker can only ever offer legal references — the designer
 * should make an invalid workflow hard to draw rather than merely reject it on
 * publish.
 */

import { outputsFor, NODE_TYPES } from "./nodeCatalog";

/** Reserved selector roots that are not node ids. */
export const SCOPES = {
  SYS: "sys",
  ENV: "env",
  CONVERSATION: "conversation",
};

/** `["node1","text"]` → `"{{#node1.text#}}"`. */
export const toRef = (selector) =>
  Array.isArray(selector) && selector.length ? `{{#${selector.join(".")}#}}` : "";

/** `"{{#node1.text#}}"` → `["node1","text"]`; null when it isn't a reference. */
export function fromRef(ref) {
  const m = /^\{\{#([^#}]+)#\}\}$/.exec(String(ref || "").trim());
  return m ? m[1].split(".") : null;
}

/** Every `{{#…#}}` occurrence inside a template, as selector arrays. */
export function parseRefs(text) {
  const out = [];
  const re = /\{\{#([^#}]+)#\}\}/g;
  let m;
  while ((m = re.exec(String(text || "")))) out.push(m[1].split("."));
  return out;
}

/** Replaces each reference in `text` using `resolve(selector)`. */
export function renderRefs(text, resolve) {
  return String(text || "").replace(/\{\{#([^#}]+)#\}\}/g, (whole, body) => {
    const v = resolve(body.split("."));
    return v === undefined || v === null ? whole : String(v);
  });
}

/**
 * All ancestors of `nodeId`, nearest first.
 *
 * Breadth-first over reversed edges. `seen` also guards the cycle case — Dify
 * permits loops via the loop node, and a cyclic edge set must not hang the UI.
 */
export function upstreamOf(nodeId, nodes, edges) {
  const byTarget = new Map();
  for (const e of edges || []) {
    if (!byTarget.has(e.target)) byTarget.set(e.target, []);
    byTarget.get(e.target).push(e.source);
  }
  const byId = new Map((nodes || []).map((n) => [n.id, n]));
  const seen = new Set([nodeId]);
  const ordered = [];
  let frontier = byTarget.get(nodeId) || [];
  while (frontier.length) {
    const next = [];
    for (const id of frontier) {
      if (seen.has(id)) continue;
      seen.add(id);
      const node = byId.get(id);
      if (node) ordered.push(node);
      next.push(...(byTarget.get(id) || []));
    }
    frontier = next;
  }
  return ordered;
}

/**
 * Variables `nodeId` may legally reference, grouped by their source node.
 *
 * A node nested inside an iteration/loop container also sees that container's
 * per-item variables, which are not reachable through the edge graph — the
 * container is the node's parent, not its predecessor.
 */
export function availableVariables(nodeId, nodes, edges, opts = {}) {
  const { appMode = "workflow", envVariables = [], conversationVariables = [] } = opts;
  const groups = [];
  const byId = new Map((nodes || []).map((n) => [n.id, n]));
  const self = byId.get(nodeId);

  for (const node of upstreamOf(nodeId, nodes, edges)) {
    const vars = outputsFor(node);
    if (!vars.length) continue;
    groups.push({
      scope: "node",
      id: node.id,
      title: node.data?.title || NODE_TYPES[node.type]?.label || node.type,
      nodeType: node.type,
      variables: vars.map((v) => ({
        ...v,
        selector: [node.id, ...v.name.split(".")],
        ref: toRef([node.id, ...v.name.split(".")]),
      })),
    });
  }

  // Enclosing iteration/loop containers, walking up the parent chain.
  let parentId = self?.parentId;
  while (parentId) {
    const parent = byId.get(parentId);
    if (!parent) break;
    if (parent.type === "iteration") {
      groups.unshift({
        scope: "container",
        id: parent.id,
        title: parent.data?.title || "Iteration",
        nodeType: parent.type,
        variables: [
          { name: "item", type: "string", selector: [parent.id, "item"], ref: toRef([parent.id, "item"]) },
          { name: "index", type: "number", selector: [parent.id, "index"], ref: toRef([parent.id, "index"]) },
        ],
      });
    } else if (parent.type === "loop") {
      groups.unshift({
        scope: "container",
        id: parent.id,
        title: parent.data?.title || "Loop",
        nodeType: parent.type,
        variables: [
          {
            name: "loop_round",
            type: "number",
            selector: [parent.id, "loop_round"],
            ref: toRef([parent.id, "loop_round"]),
          },
          ...(parent.data?.loop_variables || []).map((v) => ({
            name: v.label || v.variable,
            type: v.value_type || "string",
            selector: [parent.id, v.variable],
            ref: toRef([parent.id, v.variable]),
          })),
        ],
      });
    }
    parentId = parent.parentId;
  }

  // System scope. `sys.query` and the dialogue counter only exist in chatflows.
  const startNode = (nodes || []).find((n) => n.type === "start");
  const sys = [
    ...(appMode === "chat"
      ? [
          { name: "sys.query", type: "string" },
          { name: "sys.conversation_id", type: "string" },
          { name: "sys.dialogue_count", type: "number" },
        ]
      : []),
    ...((NODE_TYPES.start.systemOutputs || []).map((v) => ({ ...v }))),
  ];
  groups.push({
    scope: SCOPES.SYS,
    id: startNode?.id || "sys",
    title: "System",
    variables: sys.map((v) => ({
      ...v,
      selector: v.name.split("."),
      ref: toRef(v.name.split(".")),
    })),
  });

  if (envVariables.length) {
    groups.push({
      scope: SCOPES.ENV,
      id: "env",
      title: "Environment",
      variables: envVariables.map((v) => ({
        name: v.name,
        type: v.value_type || "string",
        secret: v.value_type === "secret",
        selector: ["env", v.name],
        ref: toRef(["env", v.name]),
      })),
    });
  }

  if (appMode === "chat" && conversationVariables.length) {
    groups.push({
      scope: SCOPES.CONVERSATION,
      id: "conversation",
      title: "Conversation",
      variables: conversationVariables.map((v) => ({
        name: v.name,
        type: v.value_type || "string",
        selector: ["conversation", v.name],
        ref: toRef(["conversation", v.name]),
      })),
    });
  }

  return groups.filter((g) => g.variables.length > 0);
}

/** Flat lookup of every legal reference for `nodeId`, keyed by `"a.b"`. */
export function variableIndex(nodeId, nodes, edges, opts) {
  const index = new Map();
  for (const g of availableVariables(nodeId, nodes, edges, opts)) {
    for (const v of g.variables) index.set(v.selector.join("."), { ...v, group: g });
  }
  return index;
}

/** Human label for a selector, e.g. `Classify · class_name`. */
export function describeSelector(selector, nodes) {
  if (!Array.isArray(selector) || !selector.length) return "";
  const [head, ...rest] = selector;
  if (head === SCOPES.SYS || head === SCOPES.ENV || head === SCOPES.CONVERSATION) {
    return selector.join(".");
  }
  const node = (nodes || []).find((n) => n.id === head);
  const title = node?.data?.title || NODE_TYPES[node?.type]?.label || head;
  return `${title} · ${rest.join(".")}`;
}

/**
 * Every reference a node makes that no longer resolves — the check that turns
 * "deleted an upstream node" from a publish-time 500 into an inline warning.
 */
export function danglingRefs(node, nodes, edges, opts) {
  const index = variableIndex(node.id, nodes, edges, opts);
  const used = collectSelectors(node.data);
  return used
    .filter((sel) => !index.has(sel.join(".")))
    .map((sel) => ({ selector: sel, ref: toRef(sel), label: describeSelector(sel, nodes) }));
}

/** Walks a node's data for both selector arrays and inline `{{#…#}}` refs. */
export function collectSelectors(data) {
  const found = [];
  const seen = new Set();
  const push = (sel) => {
    const key = sel.join(".");
    if (!seen.has(key)) {
      seen.add(key);
      found.push(sel);
    }
  };

  const isSelector = (v) =>
    Array.isArray(v) && v.length >= 2 && v.every((s) => typeof s === "string");

  const walk = (value, key) => {
    if (value == null) return;
    if (typeof value === "string") {
      for (const sel of parseRefs(value)) push(sel);
      return;
    }
    if (Array.isArray(value)) {
      // `value_selector`-shaped keys hold the selector itself, not a list.
      if (isSelector(value) && /selector|query|variable$/i.test(key || "")) {
        push(value);
        return;
      }
      value.forEach((v) => walk(v, key));
      return;
    }
    if (typeof value === "object") {
      for (const [k, v] of Object.entries(value)) walk(v, k);
    }
  };

  walk(data, null);
  return found;
}

/** True when `type` can be assigned to a field expecting `expected`. */
export function typeCompatible(type, expected) {
  if (!expected || expected === "any") return true;
  if (type === expected) return true;
  // Dify coerces freely into string, and treats number as string-renderable.
  if (expected === "string") return type === "number" || type === "boolean";
  if (expected === "array" ) return String(type).startsWith("array");
  return false;
}
