/**
 * The node inspector.
 *
 * Renders a node type's `fields` array from the catalog generically: look the
 * descriptor's `type` up in FIELD_COMPONENTS, read the current value at its
 * dotted `key`, write back immutably. Nothing here knows what an LLM node is —
 * which is the point, because it means the panel never needs editing when a
 * node type is added.
 */

import React, { useMemo } from "react";
import Icon from "../Icon";
import { NODE_TYPES, getPath, setPath, outputsFor, handlesFor } from "../../lib/dify/nodeCatalog";
import { danglingRefs, toRef } from "../../lib/dify/variables";
import { FIELD_COMPONENTS, Field } from "./fields";
import { DesignerContext, useDesigner } from "./DesignerContext";

export default function NodePanel({ node, nodes, edges, onChange, onClose, onDelete, context }) {
  const def = node ? NODE_TYPES[node.type] : null;

  const ctx = useMemo(
    () => ({ ...context, nodeId: node?.id, nodes, edges }),
    [context, node?.id, nodes, edges],
  );

  const warnings = useMemo(
    () => (node ? danglingRefs(node, nodes, edges, context) : []),
    [node, nodes, edges, context],
  );

  if (!node || !def) return null;

  const data = node.data || {};
  const readOnly = context?.readOnly;

  const patch = (next) => !readOnly && onChange(node.id, next);
  const setField = (key, value) => patch(setPath(data, key, value));

  // Fields render in declaration order, bucketed by their optional `group`.
  const groups = [];
  for (const field of def.fields || []) {
    if (field.when && !field.when(data)) continue;
    if (field.chatOnly && context?.appMode !== "chat") continue;
    const name = field.group || "";
    let bucket = groups.find((g) => g.name === name);
    if (!bucket) {
      bucket = { name, fields: [] };
      groups.push(bucket);
    }
    bucket.fields.push(field);
  }

  const outputs = outputsFor(node);
  const { outputs: handles } = handlesFor(node);

  return (
    <DesignerContext.Provider value={ctx}>
      <aside className="flex h-full w-[380px] shrink-0 flex-col border-l border-slate-200 bg-white">
        {/* header */}
        <div className="shrink-0 border-b border-slate-100 px-4 py-3">
          <div className="flex items-start gap-2.5">
            <span
              className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-lg text-white"
              style={{ backgroundColor: def.color }}
            >
              <Icon name={def.icon} size={17} />
            </span>
            <div className="min-w-0 flex-1">
              <input
                value={data.title ?? def.label}
                disabled={readOnly}
                onChange={(e) => setField("title", e.target.value)}
                className="w-full truncate border-0 bg-transparent p-0 text-[15px] font-semibold leading-snug text-slate-900 outline-none focus:ring-0"
              />
              <p className="text-[11px] text-slate-500">{def.label}</p>
            </div>
            <div className="flex shrink-0 items-center gap-0.5">
              {!def.unique && !readOnly && (
                <button
                  type="button"
                  title="Delete node"
                  onClick={() => onDelete(node.id)}
                  className="flex h-7 w-7 items-center justify-center rounded-lg text-slate-400 transition hover:bg-red-50 hover:text-red-600"
                >
                  <Icon name="trash" size={15} />
                </button>
              )}
              <button
                type="button"
                title="Close"
                onClick={onClose}
                className="flex h-7 w-7 items-center justify-center rounded-lg text-slate-400 transition hover:bg-slate-100 hover:text-slate-700"
              >
                <Icon name="x" size={15} />
              </button>
            </div>
          </div>
          <input
            value={data.desc ?? ""}
            disabled={readOnly}
            onChange={(e) => setField("desc", e.target.value)}
            placeholder="Add a description…"
            className="mt-2 w-full border-0 bg-transparent p-0 text-xs text-slate-500 outline-none placeholder:text-slate-400 focus:ring-0"
          />
        </div>

        {/* body */}
        <div className="flex-1 overflow-y-auto px-4 py-4">
          {warnings.length > 0 && (
            <div className="mb-4 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2.5">
              <p className="mb-1 flex items-center gap-1.5 text-xs font-semibold text-amber-900">
                <Icon name="warning" size={14} />
                {warnings.length} reference{warnings.length > 1 ? "s" : ""} no longer resolve
              </p>
              <ul className="space-y-0.5">
                {warnings.map((w) => (
                  <li key={w.ref} className="font-mono text-[11px] text-amber-800">
                    {w.ref}
                  </li>
                ))}
              </ul>
            </div>
          )}

          <div className="space-y-5">
            {groups.map((group) => (
              <section key={group.name || "main"}>
                {group.name && (
                  <p className="mb-2.5 border-b border-slate-100 pb-1.5 text-[10px] font-bold uppercase tracking-wide text-slate-400">
                    {group.name}
                  </p>
                )}
                <div className="space-y-3.5">
                  {group.fields.map((field) => (
                    <FieldRow
                      key={field.key}
                      field={field}
                      data={data}
                      readOnly={readOnly}
                      onChange={setField}
                      onPatch={patch}
                    />
                  ))}
                </div>
              </section>
            ))}
          </div>

          {/* what this node exposes downstream */}
          {outputs.length > 0 && (
            <section className="mt-6 border-t border-slate-100 pt-4">
              <p className="mb-2 text-[10px] font-bold uppercase tracking-wide text-slate-400">
                Output variables
              </p>
              <div className="space-y-1">
                {outputs.map((o) => (
                  <div key={o.name} className="flex items-center justify-between gap-2">
                    <code className="truncate rounded bg-slate-100 px-1.5 py-0.5 font-mono text-[11px] text-slate-600">
                      {toRef([node.id, o.name])}
                    </code>
                    <span className="shrink-0 rounded bg-slate-100 px-1.5 py-0.5 font-mono text-[10px] text-slate-500">
                      {o.type}
                    </span>
                  </div>
                ))}
              </div>
            </section>
          )}

          {handles.length > 1 && (
            <section className="mt-5 border-t border-slate-100 pt-4">
              <p className="mb-2 text-[10px] font-bold uppercase tracking-wide text-slate-400">
                Branches
              </p>
              <div className="flex flex-wrap gap-1.5">
                {handles.map((h) => (
                  <span
                    key={h.id}
                    className={`rounded px-2 py-0.5 text-[11px] font-semibold ${
                      h.tone === "error" ? "bg-red-50 text-red-700" : "bg-slate-100 text-slate-600"
                    }`}
                  >
                    {h.label || h.id}
                  </span>
                ))}
              </div>
            </section>
          )}
        </div>
      </aside>
    </DesignerContext.Provider>
  );
}

/**
 * One descriptor → one editor.
 *
 * `__tool` is the one field that writes several data keys at once (provider id,
 * tool name, parameters), so it takes the whole `data` object and returns a
 * patch rather than a single value.
 */
function FieldRow({ field, data, readOnly, onChange, onPatch }) {
  const Component = FIELD_COMPONENTS[field.type];
  if (!Component) {
    return (
      <Field field={field}>
        <p className="text-xs text-slate-500">No editor for field type “{field.type}”.</p>
      </Field>
    );
  }

  if (field.key === "__tool") {
    return (
      <Field field={field}>
        <fieldset disabled={readOnly} className="border-0 p-0">
          <Component field={field} data={data} value={null} onChange={(next) => onPatch({ ...data, ...next })} />
        </fieldset>
      </Field>
    );
  }

  const value = getPath(data, field.key) ?? field.default;

  // Switches read better with the control beside the label than beneath it.
  if (field.type === "switch") {
    return (
      <div className="flex items-center justify-between gap-3">
        <div className="min-w-0">
          <p className="text-xs font-semibold text-slate-700">{field.label}</p>
          {field.help && <p className="mt-0.5 text-[11px] text-slate-500">{field.help}</p>}
        </div>
        <fieldset disabled={readOnly} className="border-0 p-0">
          <Component field={field} value={value} onChange={(v) => onChange(field.key, v)} />
        </fieldset>
      </div>
    );
  }

  return (
    <Field field={field}>
      <fieldset disabled={readOnly} className="border-0 p-0">
        <Component
          field={field}
          value={value}
          data={data}
          onChange={(v) => onChange(field.key, v)}
          language={field.languageKey ? getPath(data, field.languageKey) : undefined}
        />
      </fieldset>
    </Field>
  );
}

export { useDesigner };
