/**
 * The Dify workflow designer.
 *
 * Deliberately a separate page from WorkflowDesigner.jsx: that one drives the
 * native AutoOps engine (job-service steps, approval gates, run polling) and
 * this one edits a Dify app graph. They share nothing but the route prefix, and
 * keeping them apart means neither regresses the other.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import {
  ReactFlow,
  Background,
  Controls,
  MiniMap,
  addEdge,
  useNodesState,
  useEdgesState,
  reconnectEdge,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";

import Icon from "../../components/Icon";
import { SmallButton, Skeleton, ConfirmModal } from "../../components/app/appui";
import DifyNode from "../../components/dify/DifyNode";
import NodePanel from "../../components/dify/NodePanel";
import { paletteFor, defaultDataFor, NODE_TYPES } from "../../lib/dify/nodeCatalog";
import { difyApi, streamRun, emptyDraft } from "../../lib/dify/difyApi";
import { generateDsl, fromDsl } from "../../lib/dify/dslGenerator";
import {
  nestingTargetFor,
  reparent,
  removeWithDescendants,
  sortParentFirst,
  isContainer,
  CONTAINER_SIZE,
} from "../../lib/dify/nesting";
import { useStore } from "../../store/store";

const nodeTypes = { dify: DifyNode };

/** Node ids must be stable strings — the DSL references them by name. */
const newId = () => `n_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 5)}`;

export default function DifyDesigner() {
  const { pid, appId } = useParams();
  const { pushToast, can } = useStore();
  const readOnly = !can("editWorkflow");

  const [nodes, setNodes, onNodesChange] = useNodesState([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState([]);
  const [selectedId, setSelectedId] = useState(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [appName, setAppName] = useState("");
  const [appMode, setAppMode] = useState("workflow");

  // Catalogs the config fields need — loaded once, handed down by context.
  const [models, setModels] = useState([]);
  const [toolProviders, setToolProviders] = useState([]);
  const [datasets, setDatasets] = useState([]);
  const [envVariables, setEnvVariables] = useState([]);
  const [conversationVariables, setConversationVariables] = useState([]);

  const [problems, setProblems] = useState(null);
  const [runOpen, setRunOpen] = useState(false);
  const [runEvents, setRunEvents] = useState([]);
  const [running, setRunning] = useState(false);
  const abortRef = useRef(null);

  const flowWrapper = useRef(null);
  const fileInputRef = useRef(null);
  const [pendingImport, setPendingImport] = useState(null);
  const [rf, setRf] = useState(null);

  // ---- load ---------------------------------------------------------------
  useEffect(() => {
    let live = true;
    setLoading(true);
    Promise.all([
      difyApi.getApp(appId).catch(() => null),
      difyApi.getDraft(appId).catch(() => emptyDraft()),
      difyApi.listAvailableModels("llm").catch(() => []),
      difyApi.listToolProviders().catch(() => []),
      difyApi.listDatasets().catch(() => []),
    ])
      .then(([app, draft, modelList, tools, ds]) => {
        if (!live) return;
        if (app) {
          setAppName(app.name || "");
          setAppMode(app.mode || "workflow");
        }
        const g = draft?.graph || emptyDraft().graph;
        // Parents must precede children or reactflow throws on first render.
        setNodes(sortParentFirst((g.nodes || []).map(toFlowNode)));
        setEdges(g.edges || []);
        setEnvVariables(draft?.environment_variables || []);
        setConversationVariables(draft?.conversation_variables || []);
        setModels(modelList);
        setToolProviders(tools);
        setDatasets(ds);
      })
      .catch((e) => live && pushToast(e.message || "Failed to load the workflow", "red"))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [appId, setNodes, setEdges, pushToast]);

  // ---- graph edits --------------------------------------------------------
  const markDirty = useCallback(() => setDirty(true), []);

  const onConnect = useCallback(
    (params) => {
      setEdges((eds) => addEdge({ ...params, type: "smoothstep" }, eds));
      markDirty();
    },
    [setEdges, markDirty],
  );

  const onReconnect = useCallback(
    (oldEdge, newConnection) => {
      setEdges((eds) => reconnectEdge(oldEdge, newConnection, eds));
      markDirty();
    },
    [setEdges, markDirty],
  );

  /**
   * Adds a node, attaching it to whatever container it was dropped onto.
   * Dropping straight into an iteration is the natural gesture, so it should
   * not require a second drag to nest.
   */
  const addNode = useCallback(
    (type, at) => {
      if (readOnly) return;
      const id = newId();
      const position = at || {
        x: 260 + (nodes.length % 4) * 60,
        y: 120 + nodes.length * 30,
      };
      const fresh = {
        id,
        type: "dify",
        position,
        data: defaultDataFor(type),
        ...(NODE_TYPES[type]?.container ? { style: { ...CONTAINER_SIZE } } : {}),
      };
      setNodes((ns) => {
        const withNode = [...ns, fresh];
        const target = at ? nestingTargetFor(fresh, withNode) : null;
        return target ? reparent(withNode, id, target.id) : withNode;
      });
      setSelectedId(id);
      markDirty();
    },
    [nodes.length, readOnly, setNodes, markDirty],
  );

  /**
   * Nesting happens on drop, not during the drag: reactflow has already
   * committed the new position by the time this fires, so the node's centre is
   * the honest test for which container it landed in.
   */
  const onNodeDragStop = useCallback(
    (_, dragged) => {
      if (readOnly) return;
      setNodes((ns) => {
        const node = ns.find((n) => n.id === dragged.id);
        if (!node) return ns;
        const target = nestingTargetFor(node, ns);
        const next = reparent(ns, node.id, target?.id || null);
        if (next !== ns) markDirty();
        return next;
      });
    },
    [readOnly, setNodes, markDirty],
  );

  const updateNodeData = useCallback(
    (id, data) => {
      setNodes((ns) => ns.map((n) => (n.id === id ? { ...n, data } : n)));
      markDirty();
    },
    [setNodes, markDirty],
  );

  const deleteNode = useCallback(
    (id) => {
      // Deleting a container takes its sub-flow with it — a surviving child
      // would keep a parentId pointing at nothing, which reactflow crashes on.
      setNodes((ns) => {
        const remaining = removeWithDescendants(ns, id);
        const gone = new Set(
          ns.filter((n) => !remaining.some((r) => r.id === n.id)).map((n) => n.id),
        );
        setEdges((es) => es.filter((e) => !gone.has(e.source) && !gone.has(e.target)));
        return remaining;
      });
      setSelectedId(null);
      markDirty();
    },
    [setNodes, setEdges, markDirty],
  );

  const onDrop = useCallback(
    (event) => {
      event.preventDefault();
      const type = event.dataTransfer.getData("application/dify-node");
      if (!type || !rf) return;
      addNode(type, rf.screenToFlowPosition({ x: event.clientX, y: event.clientY }));
    },
    [rf, addNode],
  );

  // ---- persistence --------------------------------------------------------
  const graph = useMemo(
    () => ({
      nodes: nodes.map(toDraftNode),
      edges: edges.map((e) => ({
        id: e.id,
        source: e.source,
        target: e.target,
        sourceHandle: e.sourceHandle || "source",
        targetHandle: e.targetHandle || "target",
        // The DSL wants both endpoint types on the edge itself.
        sourceType: nodes.find((n) => n.id === e.source)?.data?.type,
        targetType: nodes.find((n) => n.id === e.target)?.data?.type,
      })),
      viewport: rf?.getViewport?.() || { x: 0, y: 0, zoom: 0.9 },
    }),
    [nodes, edges, rf],
  );

  const save = async () => {
    setSaving(true);
    try {
      await difyApi.saveDraft(appId, {
        graph,
        environment_variables: envVariables,
        conversation_variables: conversationVariables,
      });
      setDirty(false);
      pushToast("Draft saved", "green");
    } catch (e) {
      pushToast(e.message || "Save failed", "red");
    } finally {
      setSaving(false);
    }
  };

  /** The DSL input assembled from current editor state. */
  const dslInput = useMemo(
    () => ({
      app: { name: appName, mode: appMode },
      graph,
      environmentVariables: envVariables,
      conversationVariables,
    }),
    [appName, appMode, graph, envVariables, conversationVariables],
  );

  /**
   * Publish generates the DSL first and refuses on any error. Dify accepts a
   * broken graph with a 200 and only fails at run time, so catching it here is
   * the difference between an inline message and a mystery failure later.
   */
  const publish = async () => {
    const { yaml, errors, warnings } = generateDsl(dslInput);
    setProblems(errors.length || warnings.length ? { errors, warnings } : null);
    if (errors.length) {
      pushToast(`${errors.length} problem${errors.length > 1 ? "s" : ""} must be fixed first`, "red");
      return;
    }

    setSaving(true);
    try {
      await difyApi.saveDraft(appId, {
        graph,
        environment_variables: envVariables,
        conversation_variables: conversationVariables,
        dsl: yaml,
      });
      await difyApi.publish(appId);
      setDirty(false);
      pushToast("Published — the Service API will now serve this version", "green");
    } catch (e) {
      pushToast(e.message || "Publish failed", "red");
    } finally {
      setSaving(false);
    }
  };

  /**
   * Import replaces the whole canvas, so a parse failure must never get that
   * far: errors are reported and the existing graph is left alone. A readable
   * file goes to a confirmation step first, since the replacement is not undoable.
   */
  const onImportFile = async (event) => {
    const file = event.target.files?.[0];
    event.target.value = ""; // let the same file be picked again after a fix
    if (!file) return;

    let result;
    try {
      result = fromDsl(await file.text());
    } catch {
      pushToast("Could not read that file", "red");
      return;
    }

    if (result.errors.length) {
      setProblems({ errors: result.errors, warnings: result.warnings });
      pushToast(result.errors[0].message, "red");
      return;
    }
    setPendingImport({ ...result, fileName: file.name });
  };

  const applyImport = () => {
    const incoming = pendingImport;
    if (!incoming) return;

    setNodes(sortParentFirst((incoming.graph.nodes || []).map(toFlowNode)));
    setEdges((incoming.graph.edges || []).map((e) => ({ ...e, type: "smoothstep" })));
    if (incoming.app?.name) setAppName(incoming.app.name);
    if (incoming.app?.mode) setAppMode(incoming.app.mode);
    setEnvVariables(incoming.environmentVariables || []);
    setConversationVariables(incoming.conversationVariables || []);

    setSelectedId(null);
    // Warnings survive the import so "3 nodes were dropped" stays on screen.
    setProblems(incoming.warnings.length ? { errors: [], warnings: incoming.warnings } : null);
    setPendingImport(null);
    markDirty();
    pushToast(`Imported ${incoming.graph.nodes.length} nodes from ${incoming.fileName}`, "green");
  };

  /** Export is deliberately non-strict — a broken graph is what you want to read. */
  const exportDsl = () => {
    const { yaml, errors, warnings } = generateDsl(dslInput, { strict: false });
    setProblems(errors.length || warnings.length ? { errors, warnings } : null);
    const url = URL.createObjectURL(new Blob([yaml], { type: "application/x-yaml" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = `${(appName || "workflow").replace(/[^\w.-]+/g, "-").toLowerCase()}.yml`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  };

  // ---- run ----------------------------------------------------------------
  const startRun = async () => {
    setRunOpen(true);
    setRunEvents([]);
    setRunning(true);
    setNodes((ns) => ns.map((n) => ({ ...n, data: { ...n.data, __runState: undefined } })));

    const controller = new AbortController();
    abortRef.current = controller;
    try {
      await streamRun(
        appId,
        {},
        (evt) => {
          setRunEvents((prev) => [...prev, evt]);
          // Mirror node lifecycle onto the canvas so progress is visible where
          // the user is already looking, not only in the log.
          if (evt.event === "node_started") {
            setNodes((ns) =>
              ns.map((n) =>
                n.id === evt.data.node_id ? { ...n, data: { ...n.data, __runState: "running" } } : n,
              ),
            );
          } else if (evt.event === "node_finished") {
            setNodes((ns) =>
              ns.map((n) =>
                n.id === evt.data.node_id
                  ? {
                      ...n,
                      data: {
                        ...n.data,
                        __runState: evt.data.status === "succeeded" ? "succeeded" : "failed",
                      },
                    }
                  : n,
              ),
            );
          }
        },
        { signal: controller.signal, draft: true },
      );
    } catch (e) {
      if (e.name !== "AbortError") pushToast(e.message || "Run failed", "red");
    } finally {
      setRunning(false);
      abortRef.current = null;
    }
  };

  const stopRun = () => {
    abortRef.current?.abort();
    setRunning(false);
  };

  const selected = nodes.find((n) => n.id === selectedId) || null;
  const selectedForPanel = selected
    ? { id: selected.id, type: selected.data.type, data: selected.data, parentId: selected.parentId }
    : null;
  const panelNodes = useMemo(
    () => nodes.map((n) => ({ id: n.id, type: n.data.type, data: n.data, parentId: n.parentId })),
    [nodes],
  );

  /**
   * A container only shows its "drop nodes here" hint while it is empty, so the
   * hint never sits behind the children it was asking for. Derived per render
   * rather than stored, keeping it out of the persisted graph.
   */
  const flowNodes = useMemo(
    () =>
      nodes.map((n) =>
        isContainer(n)
          ? { ...n, data: { ...n.data, __hasChildren: nodes.some((c) => c.parentId === n.id) } }
          : n,
      ),
    [nodes],
  );

  const designerContext = useMemo(
    () => ({ appMode, models, toolProviders, datasets, envVariables, conversationVariables, readOnly }),
    [appMode, models, toolProviders, datasets, envVariables, conversationVariables, readOnly],
  );

  return (
    <div className="flex h-[calc(100vh-4rem)] flex-col">
      {/* toolbar */}
      <header className="flex shrink-0 items-center justify-between gap-3 border-b border-slate-200 bg-white px-4 py-2.5">
        <div className="flex min-w-0 items-center gap-3">
          <Link
            to={`/app/projects/${pid}/workflows`}
            className="flex h-8 w-8 items-center justify-center rounded-lg text-slate-400 transition hover:bg-slate-100 hover:text-slate-700"
          >
            <Icon name="chevron" size={16} className="rotate-180" />
          </Link>
          <div className="min-w-0">
            <p className="truncate text-sm font-semibold text-slate-900">
              {loading ? <Skeleton className="h-4 w-40" /> : appName || "Untitled"}
            </p>
            <p className="text-[11px] text-slate-500">
              Dify {appMode === "chat" ? "chatflow" : "workflow"}
              {dirty && <span className="ml-1.5 text-amber-600">· unsaved changes</span>}
            </p>
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <SmallButton icon="play" onClick={startRun} disabled={running || loading}>
            {running ? "Running…" : "Test run"}
          </SmallButton>
          <SmallButton icon="doc" onClick={exportDsl} disabled={loading}>
            Export DSL
          </SmallButton>
          <SmallButton
            icon="plus"
            onClick={() => fileInputRef.current?.click()}
            disabled={loading || readOnly}
          >
            Import DSL
          </SmallButton>
          <input
            ref={fileInputRef}
            type="file"
            accept=".yml,.yaml,.dsl,text/yaml,application/x-yaml"
            onChange={onImportFile}
            className="hidden"
            data-testid="dsl-file-input"
          />
          <SmallButton icon="check" onClick={save} disabled={saving || readOnly || loading}>
            Save draft
          </SmallButton>
          <SmallButton icon="bolt" variant="primary" onClick={publish} disabled={saving || readOnly || loading}>
            Publish
          </SmallButton>
        </div>
      </header>

      <div className="flex min-h-0 flex-1">
        {/* palette */}
        <aside className="w-56 shrink-0 overflow-y-auto border-r border-slate-200 bg-white px-3 py-3">
          <p className="mb-2 text-[10px] font-bold uppercase tracking-wide text-slate-400">Nodes</p>
          {paletteFor(appMode).map((group) => (
            <div key={group.key} className="mb-4">
              <p className="mb-1.5 text-[11px] font-semibold text-slate-500">{group.label}</p>
              <div className="space-y-1">
                {group.nodes.map((n) => (
                  <button
                    key={n.type}
                    type="button"
                    draggable={!readOnly}
                    onDragStart={(e) => e.dataTransfer.setData("application/dify-node", n.type)}
                    onClick={() => addNode(n.type)}
                    disabled={readOnly}
                    title={n.description}
                    className="flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left transition hover:bg-slate-50 disabled:opacity-40"
                  >
                    <span
                      className="flex h-6 w-6 shrink-0 items-center justify-center rounded text-white"
                      style={{ backgroundColor: n.color }}
                    >
                      <Icon name={n.icon} size={13} />
                    </span>
                    <span className="truncate text-xs font-medium text-slate-700">{n.label}</span>
                  </button>
                ))}
              </div>
            </div>
          ))}
        </aside>

        {/* canvas */}
        <div ref={flowWrapper} className="min-w-0 flex-1 bg-slate-50">
          {loading ? (
            <div className="flex h-full items-center justify-center">
              <Skeleton className="h-40 w-80" />
            </div>
          ) : (
            <ReactFlow
              nodes={flowNodes}
              edges={edges}
              nodeTypes={nodeTypes}
              onInit={setRf}
              onNodesChange={(c) => {
                onNodesChange(c);
                if (c.some((x) => x.type === "position" || x.type === "remove")) markDirty();
              }}
              onEdgesChange={(c) => {
                onEdgesChange(c);
                if (c.some((x) => x.type === "remove")) markDirty();
              }}
              onConnect={onConnect}
              onReconnect={onReconnect}
              onNodeDragStop={onNodeDragStop}
              onNodeClick={(_, n) => setSelectedId(n.id)}
              onPaneClick={() => setSelectedId(null)}
              onDrop={onDrop}
              onDragOver={(e) => {
                e.preventDefault();
                e.dataTransfer.dropEffect = "move";
              }}
              nodesDraggable={!readOnly}
              nodesConnectable={!readOnly}
              edgesReconnectable={!readOnly}
              fitView
              proOptions={{ hideAttribution: true }}
              defaultEdgeOptions={{ type: "smoothstep" }}
            >
              <Background gap={16} color="#cbd5e1" />
              <Controls showInteractive={false} />
              <MiniMap pannable zoomable nodeColor={(n) => NODE_TYPES[n.data?.type]?.color || "#94a3b8"} />
            </ReactFlow>
          )}
        </div>

        {/* inspector */}
        {selectedForPanel && (
          <NodePanel
            node={selectedForPanel}
            nodes={panelNodes}
            edges={edges}
            context={designerContext}
            onChange={updateNodeData}
            onClose={() => setSelectedId(null)}
            onDelete={deleteNode}
          />
        )}
      </div>

      <ConfirmModal
        open={!!pendingImport}
        title="Replace this workflow?"
        message={
          pendingImport
            ? `${pendingImport.fileName} contains ${pendingImport.graph.nodes.length} nodes. Importing discards everything currently on the canvas — this cannot be undone.`
            : ""
        }
        confirmLabel="Import"
        onConfirm={applyImport}
        onClose={() => setPendingImport(null)}
      />

      {/* validation results */}
      {problems && (
        <ProblemsPanel
          problems={problems}
          onClose={() => setProblems(null)}
          onSelect={(nodeId) => nodeId && setSelectedId(nodeId)}
        />
      )}

      {/* run console */}
      {runOpen && (
        <RunConsole
          events={runEvents}
          running={running}
          onStop={stopRun}
          onClose={() => setRunOpen(false)}
        />
      )}
    </div>
  );
}

/** Draft graph node → reactflow node. All node types share one renderer. */
const toFlowNode = (n) => {
  const type = n.data?.type || n.type;
  const container = !!NODE_TYPES[type]?.container;
  return {
    id: n.id,
    type: "dify",
    position: n.position || { x: 0, y: 0 },
    ...(n.parentId ? { parentId: n.parentId, extent: "parent", zIndex: 1 } : {}),
    // reactflow sizes a parent frame from its style, not its rendered content.
    ...(container ? { style: { ...CONTAINER_SIZE } } : {}),
    data: { ...n.data, type },
  };
};

/** reactflow node → draft graph node (drops render-only keys). */
const toDraftNode = (n) => {
  const data = { ...(n.data || {}) };
  delete data.__runState; // canvas-only run decoration, never persisted
  delete data.__hasChildren; // derived per render, not part of the graph
  return {
    id: n.id,
    type: data.type,
    position: n.position,
    ...(n.parentId ? { parentId: n.parentId } : {}),
    data,
  };
};

/**
 * Validation results. Clicking a row selects the offending node, because the
 * message alone rarely tells you which of four LLM nodes is the broken one.
 */
function ProblemsPanel({ problems, onClose, onSelect }) {
  const { errors, warnings } = problems;
  const rows = [
    ...errors.map((e) => ({ ...e, level: "error" })),
    ...warnings.map((w) => ({ ...w, level: "warning" })),
  ];

  return (
    <div className="max-h-48 shrink-0 overflow-y-auto border-t border-slate-200 bg-white">
      <div className="sticky top-0 flex items-center justify-between border-b border-slate-100 bg-white px-4 py-2">
        <p className="text-xs font-semibold text-slate-700">
          {errors.length > 0 ? (
            <span className="text-red-600">
              {errors.length} error{errors.length > 1 ? "s" : ""}
            </span>
          ) : (
            <span className="text-emerald-600">Valid</span>
          )}
          {warnings.length > 0 && (
            <span className="ml-2 text-amber-600">
              {warnings.length} warning{warnings.length > 1 ? "s" : ""}
            </span>
          )}
        </p>
        <button
          type="button"
          onClick={onClose}
          className="flex h-7 w-7 items-center justify-center rounded-lg text-slate-400 transition hover:bg-slate-100"
        >
          <Icon name="x" size={14} />
        </button>
      </div>
      <ul className="divide-y divide-slate-50">
        {rows.map((r, i) => (
          <li key={`${r.code}-${r.nodeId || i}`}>
            <button
              type="button"
              onClick={() => onSelect(r.nodeId)}
              className="flex w-full items-start gap-2 px-4 py-2 text-left transition hover:bg-slate-50"
            >
              <Icon
                name={r.level === "error" ? "warning" : "warning"}
                size={14}
                className={r.level === "error" ? "mt-0.5 text-red-500" : "mt-0.5 text-amber-500"}
              />
              <span className="min-w-0 flex-1 text-xs leading-relaxed text-slate-700">{r.message}</span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

function RunConsole({ events, running, onStop, onClose }) {
  const endRef = useRef(null);
  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [events.length]);

  const text = events
    .filter((e) => e.event === "text_chunk")
    .map((e) => e.data?.text || "")
    .join("");

  return (
    <div className="h-64 shrink-0 border-t border-slate-200 bg-white">
      <div className="flex items-center justify-between border-b border-slate-100 px-4 py-2">
        <div className="flex items-center gap-2">
          <span
            className={`h-2 w-2 rounded-full ${running ? "animate-pulse bg-blue-500" : "bg-slate-300"}`}
          />
          <p className="text-xs font-semibold text-slate-700">
            {running ? "Running" : "Run finished"}
          </p>
        </div>
        <div className="flex items-center gap-1">
          {running && (
            <button
              type="button"
              onClick={onStop}
              className="rounded-lg px-2 py-1 text-xs font-semibold text-slate-500 transition hover:bg-slate-100 hover:text-red-600"
            >
              Stop
            </button>
          )}
          <button
            type="button"
            onClick={onClose}
            className="flex h-7 w-7 items-center justify-center rounded-lg text-slate-400 transition hover:bg-slate-100"
          >
            <Icon name="x" size={14} />
          </button>
        </div>
      </div>
      <div className="grid h-[calc(100%-2.5rem)] grid-cols-2 divide-x divide-slate-100">
        <div className="overflow-y-auto px-4 py-2">
          <p className="mb-1.5 text-[10px] font-bold uppercase tracking-wide text-slate-400">Events</p>
          {events.length === 0 && <p className="text-xs text-slate-400">Waiting for the first event…</p>}
          {events.map((e, i) => (
            <div key={i} className="flex items-baseline gap-2 py-0.5">
              <span className="w-28 shrink-0 font-mono text-[10px] text-slate-400">{e.event}</span>
              <span className="min-w-0 flex-1 truncate text-[11px] text-slate-600">
                {e.data?.title || e.data?.status || e.data?.text || ""}
                {e.data?.elapsed_time != null && (
                  <span className="ml-1 text-slate-400">{e.data.elapsed_time}s</span>
                )}
              </span>
            </div>
          ))}
          <div ref={endRef} />
        </div>
        <div className="overflow-y-auto px-4 py-2">
          <p className="mb-1.5 text-[10px] font-bold uppercase tracking-wide text-slate-400">Output</p>
          <pre className="whitespace-pre-wrap font-mono text-[11.5px] leading-relaxed text-slate-700">
            {text || "—"}
          </pre>
        </div>
      </div>
    </div>
  );
}
