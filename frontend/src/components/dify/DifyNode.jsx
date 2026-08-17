/**
 * The canvas renderer for every Dify node type.
 *
 * One component covers all of them because the catalog supplies the differences
 * — colour, glyph, and the port list from `handlesFor()`, which is why branching
 * nodes grow a labelled handle per case without a bespoke component each.
 */

import React from "react";
import { Handle, Position } from "@xyflow/react";
import Icon from "../Icon";
import { NODE_TYPES, handlesFor } from "../../lib/dify/nodeCatalog";

/** Border/ring treatment for a node's live run state. */
const RUN_STYLES = {
  running: "ring-2 ring-blue-400 border-blue-300",
  succeeded: "ring-2 ring-emerald-400 border-emerald-300",
  failed: "ring-2 ring-red-400 border-red-300",
};

const STATUS_DOT = {
  running: "bg-blue-500 animate-pulse",
  succeeded: "bg-emerald-500",
  failed: "bg-red-500",
};

export default function DifyNode({ id, data, selected }) {
  const def = NODE_TYPES[data.type] || {};
  const node = { id, type: data.type, data };
  const { inputs, outputs } = handlesFor(node);
  const runState = data.__runState;
  const isContainer = def.container;

  return (
    <div
      className={`relative rounded-xl border shadow-sm transition ${
        selected ? "border-blue-500 ring-2 ring-blue-200" : "border-slate-200"
      } ${RUN_STYLES[runState] || ""} ${
        // A container fills the frame reactflow sized from its style, so its
        // children — which are separate nodes positioned inside it — land on
        // top of the body rather than beside it.
        isContainer ? "h-full w-full bg-slate-100/70" : "w-[240px] bg-white"
      }`}
    >
      {inputs.map((h) => (
        <Handle
          key={h.id}
          id={h.id}
          type="target"
          position={Position.Left}
          className="!h-2.5 !w-2.5 !border-2 !border-white !bg-slate-400"
        />
      ))}

      <div className="flex items-start gap-2.5 px-3 py-2.5">
        <span
          className="flex h-7 w-7 shrink-0 items-center justify-center rounded-lg text-white"
          style={{ backgroundColor: def.color || "#64748b" }}
        >
          <Icon name={def.icon || "bolt"} size={15} />
        </span>
        <div className="min-w-0 flex-1">
          <p className="truncate text-[13px] font-semibold leading-tight text-slate-900">
            {data.title || def.label || data.type}
          </p>
          {data.desc ? (
            <p className="mt-0.5 line-clamp-2 text-[11px] leading-snug text-slate-500">{data.desc}</p>
          ) : (
            <p className="mt-0.5 text-[11px] text-slate-400">{def.label}</p>
          )}
        </div>
        {runState && (
          <span className={`mt-1 h-2 w-2 shrink-0 rounded-full ${STATUS_DOT[runState] || "bg-slate-300"}`} />
        )}
      </div>

      {/* A model-backed node shows which model it will call — the single most
          useful thing to see without opening the panel. */}
      {data.model?.name && (
        <div className="border-t border-slate-100 px-3 py-1.5">
          <span className="truncate rounded bg-slate-100 px-1.5 py-0.5 font-mono text-[10px] text-slate-500">
            {data.model.name}
          </span>
        </div>
      )}

      {/* The hint retires once there is something inside to look at. */}
      {isContainer && !data.__hasChildren && (
        <div className="pointer-events-none absolute inset-x-3 bottom-3 top-14 rounded-lg border border-dashed border-slate-300">
          <p className="absolute inset-0 flex items-center justify-center text-[11px] text-slate-400">
            Drag nodes in here to build the sub-flow
          </p>
        </div>
      )}

      {/* Source handles. Multi-branch nodes stack them down the right edge with
          their case label beside each, matching Dify's own layout. */}
      {outputs.length <= 1
        ? outputs.map((h) => (
            <Handle
              key={h.id}
              id={h.id}
              type="source"
              position={Position.Right}
              className="!h-2.5 !w-2.5 !border-2 !border-white !bg-slate-400"
            />
          ))
        : (
            <div className="border-t border-slate-100">
              {outputs.map((h) => (
                <div key={h.id} className="relative flex items-center justify-end px-3 py-1.5">
                  <span
                    className={`text-[10px] font-bold uppercase tracking-wide ${
                      h.tone === "error" ? "text-red-500" : "text-slate-400"
                    }`}
                  >
                    {h.label || h.id}
                  </span>
                  <Handle
                    id={h.id}
                    type="source"
                    position={Position.Right}
                    className={`!h-2.5 !w-2.5 !border-2 !border-white ${
                      h.tone === "error" ? "!bg-red-400" : "!bg-slate-400"
                    }`}
                    style={{ top: "50%" }}
                  />
                </div>
              ))}
            </div>
          )}
    </div>
  );
}
