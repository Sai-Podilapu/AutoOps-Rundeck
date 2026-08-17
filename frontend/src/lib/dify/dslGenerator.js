/**
 * Canvas → Dify DSL.
 *
 * Turns the designer's graph into the YAML document Dify's importer accepts
 * (`kind: app`, `version: 0.6.0`). Two things make this more than a JSON dump:
 *
 *  1. Dify wraps every node in a reactflow shell — `type: "custom"` on the
 *     outside, the real node type inside `data.type` — and containers repeat
 *     their identity on each child (`parentId`, `iteration_id`, `isInIteration`)
 *     as well as needing a synthetic `*-start` marker node that the canvas
 *     never shows.
 *  2. An invalid graph imports with a 200 and then fails opaquely at run time,
 *     so `validateGraph` runs first and refuses to emit rather than shipping
 *     something that breaks later.
 */

import { dump, load } from "js-yaml";
import { NODE_TYPES, handlesFor, getPath } from "./nodeCatalog";
import { danglingRefs } from "./variables";

export const DSL_VERSION = "0.6.0";

/** Dify's own default canvas geometry — it re-measures on import anyway. */
const NODE_W = 244;
const NODE_H = 54;
const CONTAINER_W = 640;
const CONTAINER_H = 300;

/** Keys the canvas adds for rendering that must never reach the DSL. */
const UI_ONLY = new Set(["__runState", "__hasChildren", "selected"]);

const stripUiKeys = (data) =>
  Object.fromEntries(Object.entries(data || {}).filter(([k]) => !UI_ONLY.has(k)));

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/**
 * Pre-flight checks. `errors` block generation; `warnings` are shown but let
 * the user publish anyway — an unreachable node is legal, just probably a
 * mistake.
 */
export function validateGraph(graph, opts = {}) {
  const errors = [];
  const warnings = [];
  const nodes = graph?.nodes || [];
  const edges = graph?.edges || [];
  const appMode = opts.appMode || "workflow";

  const label = (n) => n.data?.title || NODE_TYPES[n.data?.type || n.type]?.label || n.id;
  const typeOf = (n) => n.data?.type || n.type;

  // --- entry point
  const starts = nodes.filter((n) => typeOf(n) === "start");
  if (starts.length === 0) {
    errors.push({ code: "no_start", message: "The workflow needs a Start node." });
  } else if (starts.length > 1) {
    errors.push({
      code: "multiple_start",
      message: `Only one Start node is allowed — found ${starts.length}.`,
    });
  }

  if (appMode === "workflow" && !nodes.some((n) => typeOf(n) === "end")) {
    warnings.push({
      code: "no_end",
      message: "No End node — the run will finish without declaring an output.",
    });
  }
  if (appMode === "chat" && !nodes.some((n) => typeOf(n) === "answer")) {
    warnings.push({ code: "no_answer", message: "A chatflow with no Answer node replies with nothing." });
  }

  const incoming = new Set(edges.map((e) => e.target));
  const outgoingByNode = new Map();
  for (const e of edges) {
    if (!outgoingByNode.has(e.source)) outgoingByNode.set(e.source, new Set());
    outgoingByNode.get(e.source).add(e.sourceHandle || "source");
  }

  for (const node of nodes) {
    const type = typeOf(node);
    const def = NODE_TYPES[type];
    if (!def) {
      errors.push({ code: "unknown_type", nodeId: node.id, message: `Unknown node type “${type}”.` });
      continue;
    }

    if (def.chatOnly && appMode !== "chat") {
      errors.push({
        code: "chat_only",
        nodeId: node.id,
        message: `${label(node)} is only available in a chatflow.`,
      });
    }

    // Reachability. Container children connect to the container's start
    // marker, not to the outer graph, so they're exempt.
    if (type !== "start" && !incoming.has(node.id) && !node.parentId) {
      warnings.push({
        code: "unreachable",
        nodeId: node.id,
        message: `${label(node)} has no incoming connection and will never run.`,
      });
    }

    // Required config.
    for (const field of def.fields || []) {
      if (!field.required) continue;
      if (field.when && !field.when(node.data)) continue;
      const value = field.key === "__tool" ? node.data?.tool_name : getPath(node.data, field.key);
      const empty =
        value == null ||
        value === "" ||
        (Array.isArray(value) && value.length === 0) ||
        (field.type === "model" && !value?.name);
      if (empty) {
        errors.push({
          code: "missing_required",
          nodeId: node.id,
          message: `${label(node)}: “${field.label}” is required.`,
        });
      }
    }

    // Every branch of a branching node should go somewhere.
    const { outputs } = handlesFor({ ...node, type });
    if (outputs.length > 1) {
      const wired = outgoingByNode.get(node.id) || new Set();
      const loose = outputs.filter((h) => !wired.has(h.id));
      if (loose.length) {
        warnings.push({
          code: "unwired_branch",
          nodeId: node.id,
          message: `${label(node)}: ${loose.map((h) => h.label || h.id).join(", ")} ${
            loose.length > 1 ? "branches lead" : "branch leads"
          } nowhere.`,
        });
      }
    } else if (outputs.length === 1 && !outgoingByNode.has(node.id) && type !== "end") {
      warnings.push({
        code: "dead_end",
        nodeId: node.id,
        message: `${label(node)} has no outgoing connection.`,
      });
    }

    // Containers with nothing inside produce an empty sub-flow.
    if (def.container && !nodes.some((n) => n.parentId === node.id)) {
      warnings.push({
        code: "empty_container",
        nodeId: node.id,
        message: `${label(node)} has no nodes inside it.`,
      });
    }

    // Variable references that no longer resolve.
    const forRefs = { id: node.id, type, data: node.data, parentId: node.parentId };
    for (const bad of danglingRefs(forRefs, nodes.map((n) => ({ ...n, type: typeOf(n) })), edges, opts)) {
      errors.push({
        code: "dangling_ref",
        nodeId: node.id,
        message: `${label(node)} references ${bad.ref}, which no longer exists.`,
      });
    }
  }

  return { errors, warnings, valid: errors.length === 0 };
}

// ---------------------------------------------------------------------------
// Emission
// ---------------------------------------------------------------------------

/** Deterministic edge id in Dify's own format. */
const edgeId = (e) =>
  `${e.source}-${e.sourceHandle || "source"}-${e.target}-${e.targetHandle || "target"}`;

/**
 * One designer node → one DSL node. Container membership is expressed three
 * different ways in Dify's schema (parentId, extent, and a flag plus id inside
 * data) and all three have to agree or the editor renders the child outside
 * its parent.
 */
function toDslNode(node, { containersById }) {
  const type = node.data?.type || node.type;
  const def = NODE_TYPES[type] || {};
  const parent = node.parentId ? containersById.get(node.parentId) : null;
  const parentType = parent ? parent.data?.type || parent.type : null;

  const data = {
    ...stripUiKeys(node.data),
    type,
    title: node.data?.title || def.label || type,
    desc: node.data?.desc || "",
    selected: false,
  };

  if (parent) {
    if (parentType === "iteration") {
      data.isInIteration = true;
      data.iteration_id = parent.id;
    } else if (parentType === "loop") {
      data.isInLoop = true;
      data.loop_id = parent.id;
    }
  }

  // A container declares which inner node the sub-flow enters at.
  if (def.container) {
    const startId = `${node.id}start`;
    data.start_node_id = startId;
    data.startNodeType = type === "iteration" ? "iteration-start" : "loop-start";
  }

  const position = node.position || { x: 0, y: 0 };
  const dsl = {
    id: node.id,
    type: "custom",
    position,
    positionAbsolute: parent
      ? {
          x: (parent.position?.x || 0) + position.x,
          y: (parent.position?.y || 0) + position.y,
        }
      : position,
    width: def.container ? CONTAINER_W : NODE_W,
    height: def.container ? CONTAINER_H : NODE_H,
    selected: false,
    sourcePosition: "right",
    targetPosition: "left",
    data,
  };

  if (parent) {
    dsl.parentId = parent.id;
    dsl.extent = "parent";
    dsl.zIndex = 1002;
  }
  return dsl;
}

/** The invisible entry marker Dify expects inside every container. */
function containerStartNode(container) {
  const type = container.data?.type || container.type;
  const isIteration = type === "iteration";
  return {
    id: `${container.id}start`,
    type: isIteration ? "custom-iteration-start" : "custom-loop-start",
    parentId: container.id,
    extent: "parent",
    position: { x: 24, y: 68 },
    positionAbsolute: {
      x: (container.position?.x || 0) + 24,
      y: (container.position?.y || 0) + 68,
    },
    width: 44,
    height: 48,
    selected: false,
    draggable: false,
    selectable: false,
    zIndex: 1002,
    sourcePosition: "right",
    targetPosition: "left",
    data: {
      type: isIteration ? "iteration-start" : "loop-start",
      title: "",
      desc: "",
      ...(isIteration ? { isInIteration: true } : { isInLoop: true }),
    },
  };
}

function toDslEdge(edge, { byId, containersById }) {
  const source = byId.get(edge.source);
  const target = byId.get(edge.target);
  const parent = target?.parentId ? containersById.get(target.parentId) : null;
  const parentType = parent ? parent.data?.type || parent.type : null;

  return {
    id: edge.id || edgeId(edge),
    source: edge.source,
    sourceHandle: edge.sourceHandle || "source",
    target: edge.target,
    targetHandle: edge.targetHandle || "target",
    type: "custom",
    zIndex: parent ? 1002 : 0,
    data: {
      sourceType: source?.data?.type || source?.type || "",
      targetType: target?.data?.type || target?.type || "",
      isInIteration: parentType === "iteration",
      ...(parentType === "loop" ? { isInLoop: true } : {}),
    },
  };
}

/** Feature block Dify writes for every app; chat apps carry more of it. */
const defaultFeatures = (appMode) => ({
  file_upload: {
    enabled: false,
    allowed_file_types: ["image"],
    allowed_file_extensions: [],
    allowed_file_upload_methods: ["local_file", "remote_url"],
    number_limits: 3,
    fileUploadConfig: { file_size_limit: 15, image_file_size_limit: 10 },
  },
  opening_statement: "",
  retriever_resource: { enabled: true },
  sensitive_word_avoidance: { enabled: false },
  speech_to_text: { enabled: false },
  suggested_questions: [],
  suggested_questions_after_answer: { enabled: false },
  text_to_speech: { enabled: false, language: "", voice: "" },
  ...(appMode === "chat" ? {} : {}),
});

/** The DSL as a plain object — exported separately so tests can assert on it. */
export function toDsl({
  app = {},
  graph = {},
  environmentVariables = [],
  conversationVariables = [],
  features,
} = {}) {
  const appMode = app.mode || "workflow";
  const rawNodes = graph.nodes || [];
  const containersById = new Map(
    rawNodes.filter((n) => NODE_TYPES[n.data?.type || n.type]?.container).map((n) => [n.id, n]),
  );
  const byId = new Map(rawNodes.map((n) => [n.id, n]));

  const nodes = rawNodes.map((n) => toDslNode(n, { containersById }));
  // Containers get their synthetic start marker appended after their children
  // so the importer sees the parent before anything referencing it.
  for (const container of containersById.values()) {
    nodes.push(containerStartNode(container));
  }

  const edges = (graph.edges || []).map((e) => toDslEdge(e, { byId, containersById }));

  return {
    app: {
      name: app.name || "Untitled",
      description: app.description || "",
      mode: appMode,
      icon: app.icon || "🤖",
      icon_background: app.icon_background || "#FFEAD5",
      use_icon_as_answer_icon: false,
    },
    dependencies: app.dependencies || [],
    kind: "app",
    version: DSL_VERSION,
    workflow: {
      conversation_variables: conversationVariables,
      environment_variables: environmentVariables,
      features: features || defaultFeatures(appMode),
      graph: {
        edges,
        nodes,
        viewport: graph.viewport || { x: 0, y: 0, zoom: 0.9 },
      },
    },
  };
}

// ---------------------------------------------------------------------------
// Import — the inverse of everything above.
// ---------------------------------------------------------------------------

/** Node types Dify synthesises for containers and we regenerate on export. */
const MARKER_TYPES = new Set(["iteration-start", "loop-start"]);

const isMarker = (node) =>
  MARKER_TYPES.has(node?.data?.type) || String(node?.type || "").endsWith("-start");

/**
 * Parses a Dify DSL document back into the designer's graph shape.
 *
 * Deliberately tolerant: DSL exported by Dify itself carries keys we never
 * write and omits some we do, so anything unrecognised is preserved on `data`
 * rather than dropped — round-tripping someone's real workflow must not
 * quietly delete the parts this editor doesn't model yet.
 *
 * Returns `{ app, graph, environmentVariables, conversationVariables,
 * features, errors, warnings }`; `graph` is null when the document could not
 * be read at all.
 */
export function fromDsl(yamlText) {
  const errors = [];
  const warnings = [];

  // Checked before parsing: js-yaml throws on empty input, and "not valid
  // YAML" is a confusing thing to tell someone who picked the wrong file.
  if (!String(yamlText || "").trim()) {
    return { graph: null, errors: [{ code: "empty", message: "The file is empty." }], warnings };
  }

  let doc;
  try {
    doc = load(yamlText);
  } catch (e) {
    return { graph: null, errors: [{ code: "unparseable", message: `Not valid YAML — ${e.message}` }], warnings };
  }

  if (!doc || typeof doc !== "object") {
    return { graph: null, errors: [{ code: "empty", message: "The file is empty." }], warnings };
  }
  if (doc.kind && doc.kind !== "app") {
    return {
      graph: null,
      errors: [{ code: "wrong_kind", message: `Expected a Dify app export, got kind “${doc.kind}”.` }],
      warnings,
    };
  }
  if (!doc.workflow?.graph) {
    return {
      graph: null,
      errors: [{ code: "no_graph", message: "No workflow graph in this file." }],
      warnings,
    };
  }
  if (doc.version && doc.version !== DSL_VERSION) {
    warnings.push({
      code: "version_mismatch",
      message: `Built for DSL ${DSL_VERSION}; this file is ${doc.version}. Check it after importing.`,
    });
  }

  const rawNodes = Array.isArray(doc.workflow.graph.nodes) ? doc.workflow.graph.nodes : [];
  const rawEdges = Array.isArray(doc.workflow.graph.edges) ? doc.workflow.graph.edges : [];

  // Container start markers are regenerated on export, so they are dropped
  // here along with any edge that touches one.
  const markerIds = new Set(rawNodes.filter(isMarker).map((n) => n.id));

  const nodes = [];
  for (const raw of rawNodes) {
    if (markerIds.has(raw.id)) continue;
    const type = raw.data?.type || raw.type;
    if (!type) {
      warnings.push({ code: "untyped_node", message: `Skipped a node with no type (${raw.id}).` });
      continue;
    }
    if (!NODE_TYPES[type]) {
      warnings.push({
        code: "unsupported_node",
        nodeId: raw.id,
        message: `“${raw.data?.title || type}” uses node type “${type}”, which this editor cannot edit. It is kept as-is.`,
      });
    }
    const data = { ...raw.data, type };
    delete data.selected;
    nodes.push({
      id: raw.id,
      type,
      position: raw.position || { x: 0, y: 0 },
      ...(raw.parentId ? { parentId: raw.parentId } : {}),
      data,
    });
  }

  const known = new Set(nodes.map((n) => n.id));
  const edges = [];
  for (const raw of rawEdges) {
    if (markerIds.has(raw.source) || markerIds.has(raw.target)) continue;
    if (!known.has(raw.source) || !known.has(raw.target)) {
      warnings.push({
        code: "orphan_edge",
        message: `Dropped a connection to a node that is not in the file (${raw.source} → ${raw.target}).`,
      });
      continue;
    }
    edges.push({
      id: raw.id || edgeId(raw),
      source: raw.source,
      target: raw.target,
      sourceHandle: raw.sourceHandle || "source",
      targetHandle: raw.targetHandle || "target",
    });
  }

  // A child declared before its parent is legal YAML but breaks the canvas.
  const byId = new Map(nodes.map((n) => [n.id, n]));
  for (const node of nodes) {
    if (node.parentId && !byId.has(node.parentId)) {
      warnings.push({
        code: "orphan_child",
        nodeId: node.id,
        message: `“${node.data?.title || node.id}” pointed at a missing container; moved to the top level.`,
      });
      delete node.parentId;
    }
  }

  if (!nodes.some((n) => n.type === "start")) {
    warnings.push({ code: "no_start", message: "This file has no Start node." });
  }

  return {
    app: {
      name: doc.app?.name || "",
      mode: doc.app?.mode || "workflow",
      description: doc.app?.description || "",
      icon: doc.app?.icon,
      icon_background: doc.app?.icon_background,
    },
    graph: {
      nodes: sortParentFirstForImport(nodes),
      edges,
      viewport: doc.workflow.graph.viewport || { x: 0, y: 0, zoom: 0.9 },
    },
    environmentVariables: doc.workflow.environment_variables || [],
    conversationVariables: doc.workflow.conversation_variables || [],
    features: doc.workflow.features || null,
    errors,
    warnings,
  };
}

/**
 * Parents ahead of children. Duplicated rather than imported from nesting.js so
 * the DSL layer stays independent of the canvas layer; the cycle guard matters
 * here too, since an imported file is untrusted input.
 */
function sortParentFirstForImport(nodes) {
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const out = [];
  const placed = new Set();
  const visiting = new Set();
  const visit = (node) => {
    if (!node || placed.has(node.id) || visiting.has(node.id)) return;
    visiting.add(node.id);
    if (node.parentId) visit(byId.get(node.parentId));
    visiting.delete(node.id);
    placed.add(node.id);
    out.push(node);
  };
  nodes.forEach(visit);
  return out;
}

/**
 * Validate, then emit YAML.
 *
 * Returns `{ yaml, errors, warnings }` — `yaml` is null when validation failed,
 * so a caller can surface every problem at once instead of the first.
 * `strict: false` emits anyway, which the "export for debugging" path uses.
 */
export function generateDsl(input, { strict = true } = {}) {
  const { errors, warnings } = validateGraph(input.graph, {
    appMode: input.app?.mode,
    envVariables: input.environmentVariables,
    conversationVariables: input.conversationVariables,
  });

  if (strict && errors.length) return { yaml: null, errors, warnings };

  const yaml = dump(toDsl(input), {
    lineWidth: -1, // never wrap — a folded prompt changes its own meaning
    noRefs: true, // no YAML anchors; Dify's importer does not resolve them
    sortKeys: false,
    quotingType: '"',
  });

  return { yaml, errors, warnings };
}
