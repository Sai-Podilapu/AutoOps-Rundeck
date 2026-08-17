/**
 * Every editor the Dify node config panel can render.
 *
 * The panel walks a node type's `fields` array from the catalog and looks each
 * descriptor's `type` up in `FIELD_COMPONENTS`. Each editor takes the same
 * three props — `field`, `value`, `onChange` — and pulls anything else it needs
 * (the graph, the loaded model/tool/dataset catalogs) from DesignerContext.
 * That uniformity is what lets a new node type appear in the UI with no code
 * beyond its catalog entry.
 */

import React, { useMemo, useState } from "react";
import Icon from "../Icon";
import { useDesigner } from "./DesignerContext";
import { availableVariables, toRef, fromRef, describeSelector } from "../../lib/dify/variables";
import { COMPARISON_OPERATORS, VAR_TYPES } from "../../lib/dify/nodeCatalog";

const inputCls =
  "w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-slate-300 focus:ring-2 focus:ring-slate-300 disabled:opacity-50";
const miniCls =
  "rounded-lg border border-slate-200 bg-white px-2 py-1.5 text-xs text-slate-900 outline-none focus:border-slate-300 focus:ring-2 focus:ring-slate-300";

const RowButton = ({ icon, label, onClick, disabled }) => (
  <button
    type="button"
    onClick={onClick}
    disabled={disabled}
    className="inline-flex items-center gap-1.5 rounded-lg border border-dashed border-slate-300 px-3 py-1.5 text-xs font-semibold text-slate-600 transition hover:border-blue-500 hover:text-blue-600 disabled:opacity-40"
  >
    <Icon name={icon} size={14} />
    {label}
  </button>
);

const IconButton = ({ icon, onClick, title, tone = "slate" }) => (
  <button
    type="button"
    title={title}
    onClick={onClick}
    className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-lg transition hover:bg-slate-100 ${
      tone === "danger" ? "text-slate-400 hover:text-red-600" : "text-slate-400 hover:text-slate-700"
    }`}
  >
    <Icon name={icon} size={14} />
  </button>
);

export const Field = ({ field, children, error }) => (
  <div>
    {field.label && (
      <label className="mb-1.5 flex items-center gap-1.5 text-xs font-semibold text-slate-700">
        {field.label}
        {field.required && <span className="text-red-500">*</span>}
      </label>
    )}
    {children}
    {field.help && <p className="mt-1 text-[11px] leading-relaxed text-slate-500">{field.help}</p>}
    {error && <p className="mt-1 text-[11px] font-medium text-red-600">{error}</p>}
  </div>
);

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

export const TextField = ({ field, value, onChange }) => {
  const [reveal, setReveal] = useState(false);
  const secret = field.secret && !reveal;
  return (
    <div className="relative">
      <input
        type={secret ? "password" : "text"}
        value={value ?? ""}
        placeholder={field.placeholder || ""}
        onChange={(e) => onChange(e.target.value)}
        className={`${inputCls} ${field.secret ? "pr-10" : ""}`}
      />
      {field.secret && (
        <button
          type="button"
          onClick={() => setReveal((v) => !v)}
          className="absolute right-2 top-1/2 -translate-y-1/2 text-slate-400 transition hover:text-slate-700"
        >
          <Icon name={reveal ? "eye-slash" : "eye"} size={15} />
        </button>
      )}
    </div>
  );
};

export const TextareaField = ({ field, value, onChange }) => (
  <textarea
    rows={field.rows || 4}
    value={value ?? ""}
    placeholder={field.placeholder || ""}
    onChange={(e) => onChange(e.target.value)}
    className={`${inputCls} resize-y font-normal`}
  />
);

export const NumberField = ({ field, value, onChange }) => (
  <input
    type="number"
    value={value ?? ""}
    min={field.min}
    max={field.max}
    step={field.step || 1}
    onChange={(e) => onChange(e.target.value === "" ? null : Number(e.target.value))}
    className={inputCls}
  />
);

export const SwitchField = ({ value, onChange }) => (
  <button
    type="button"
    role="switch"
    aria-checked={!!value}
    onClick={() => onChange(!value)}
    className={`relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition ${
      value ? "bg-blue-600" : "bg-slate-300"
    }`}
  >
    <span
      className={`inline-block h-3.5 w-3.5 transform rounded-full bg-white transition ${
        value ? "translate-x-4.5 ml-[18px]" : "translate-x-0 ml-[3px]"
      }`}
    />
  </button>
);

export const SelectField = ({ field, value, onChange }) => (
  <select
    value={value ?? field.default ?? ""}
    onChange={(e) => onChange(e.target.value)}
    className={inputCls}
  >
    {!field.required && !field.default && <option value="">—</option>}
    {(field.options || []).map((o) => (
      <option key={o.value} value={o.value}>
        {o.label}
      </option>
    ))}
  </select>
);

/**
 * Code editor. Deliberately a textarea with tab capture rather than a bundled
 * editor — CodeMirror/Monaco would add ~700kB to a page that already carries
 * the canvas, and the payoff is syntax colour we can add later behind the same
 * props.
 */
export const CodeField = ({ field, value, onChange, language }) => {
  const lang = language || field.language || "text";
  return (
    <div className="overflow-hidden rounded-lg border border-slate-200">
      <div className="flex items-center justify-between border-b border-slate-100 bg-slate-50 px-3 py-1.5">
        <span className="text-[11px] font-semibold uppercase tracking-wide text-slate-500">{lang}</span>
        <span className="text-[11px] text-slate-400">Tab indents</span>
      </div>
      <textarea
        rows={field.rows || 10}
        value={value ?? ""}
        spellCheck={false}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={(e) => {
          if (e.key !== "Tab") return;
          e.preventDefault();
          const el = e.target;
          const next = `${el.value.slice(0, el.selectionStart)}    ${el.value.slice(el.selectionEnd)}`;
          const caret = el.selectionStart + 4;
          onChange(next);
          requestAnimationFrame(() => el.setSelectionRange(caret, caret));
        }}
        className="w-full resize-y bg-white px-3 py-2 font-mono text-[12.5px] leading-relaxed text-slate-800 outline-none"
      />
    </div>
  );
};

export const JsonField = ({ field, value, onChange }) => {
  const [text, setText] = useState(() =>
    value == null ? "" : typeof value === "string" ? value : JSON.stringify(value, null, 2),
  );
  const [error, setError] = useState(null);
  return (
    <div>
      <CodeField
        field={{ ...field, language: "json", rows: field.rows || 8 }}
        value={text}
        onChange={(t) => {
          setText(t);
          if (!t.trim()) {
            setError(null);
            onChange(null);
            return;
          }
          try {
            onChange(JSON.parse(t));
            setError(null);
          } catch (err) {
            // Keep the text so typing isn't destroyed; just flag it.
            setError(err.message);
          }
        }}
      />
      {error && <p className="mt-1 text-[11px] font-medium text-red-600">Invalid JSON — {error}</p>}
    </div>
  );
};

// ---------------------------------------------------------------------------
// Variable pickers
// ---------------------------------------------------------------------------

const typeChip = (t) => (
  <span className="rounded bg-slate-100 px-1.5 py-0.5 font-mono text-[10px] text-slate-500">{t}</span>
);

/** Selects one upstream variable, stored as a selector array. */
export const VarPicker = ({ value, onChange }) => {
  const { nodeId, nodes, edges, appMode, envVariables, conversationVariables } = useDesigner();
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");

  const groups = useMemo(
    () => availableVariables(nodeId, nodes, edges, { appMode, envVariables, conversationVariables }),
    [nodeId, nodes, edges, appMode, envVariables, conversationVariables],
  );

  const filtered = groups
    .map((g) => ({
      ...g,
      variables: g.variables.filter(
        (v) => !q || v.name.toLowerCase().includes(q.toLowerCase()) || g.title.toLowerCase().includes(q.toLowerCase()),
      ),
    }))
    .filter((g) => g.variables.length);

  const selector = Array.isArray(value) ? value : fromRef(value);
  const label = selector?.length ? describeSelector(selector, nodes) : "";

  return (
    <div className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className={`${inputCls} flex items-center justify-between text-left`}
      >
        <span className={label ? "truncate text-slate-900" : "text-slate-400"}>
          {label || "Select a variable…"}
        </span>
        <Icon name="chevron-down" size={14} />
      </button>

      {open && (
        <>
          <button
            type="button"
            aria-label="Close"
            className="fixed inset-0 z-10 cursor-default"
            onClick={() => setOpen(false)}
          />
          <div className="absolute z-20 mt-1 max-h-72 w-full overflow-y-auto rounded-xl border border-slate-200 bg-white p-2 shadow-xl">
            <input
              autoFocus
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="Search variables…"
              className={`${miniCls} mb-2 w-full`}
            />
            {filtered.length === 0 && (
              <p className="px-2 py-3 text-xs text-slate-500">
                No variables upstream of this node yet. Connect a node before it.
              </p>
            )}
            {filtered.map((g) => (
              <div key={`${g.scope}-${g.id}`} className="mb-1.5">
                <p className="px-2 py-1 text-[10px] font-bold uppercase tracking-wide text-slate-400">
                  {g.title}
                </p>
                {g.variables.map((v) => (
                  <button
                    key={v.ref}
                    type="button"
                    onClick={() => {
                      onChange(v.selector);
                      setOpen(false);
                      setQ("");
                    }}
                    className="flex w-full items-center justify-between gap-2 rounded-lg px-2 py-1.5 text-left text-xs transition hover:bg-slate-50"
                  >
                    <span className="truncate font-medium text-slate-700">{v.name}</span>
                    {typeChip(v.type)}
                  </button>
                ))}
              </div>
            ))}
          </div>
        </>
      )}

      {selector?.length > 0 && (
        <div className="mt-1.5 flex items-center gap-2">
          <code className="truncate rounded bg-slate-100 px-1.5 py-0.5 font-mono text-[11px] text-slate-600">
            {toRef(selector)}
          </code>
          <IconButton icon="x" title="Clear" onClick={() => onChange([])} />
        </div>
      )}
    </div>
  );
};

/**
 * An ordered list of variable references. `field.named` switches to the
 * name→selector form the code and template nodes use, where each input is
 * bound to a local argument name.
 */
export const VarsEditor = ({ field, value, onChange }) => {
  const rows = Array.isArray(value) ? value : [];
  const named = !!field.named;

  const update = (i, patch) => onChange(rows.map((r, idx) => (idx === i ? { ...r, ...patch } : r)));
  const add = () =>
    onChange([...rows, named ? { variable: `arg${rows.length + 1}`, value_selector: [] } : { value_selector: [] }]);

  return (
    <div className="space-y-2">
      {rows.map((row, i) => (
        <div key={i} className="rounded-lg border border-slate-200 bg-white p-2">
          <div className="mb-1.5 flex items-center gap-2">
            {named ? (
              <input
                value={row.variable ?? ""}
                onChange={(e) => update(i, { variable: e.target.value })}
                placeholder="argument name"
                className={`${miniCls} flex-1 font-mono`}
              />
            ) : (
              <span className="flex-1 text-[11px] font-semibold text-slate-500">#{i + 1}</span>
            )}
            <IconButton
              icon="trash"
              tone="danger"
              title="Remove"
              onClick={() => onChange(rows.filter((_, idx) => idx !== i))}
            />
          </div>
          <VarPicker
            field={{}}
            value={row.value_selector || row.variable_selector || []}
            onChange={(sel) => update(i, named ? { value_selector: sel } : { value_selector: sel })}
          />
        </div>
      ))}
      <RowButton icon="plus" label="Add variable" onClick={add} />
    </div>
  );
};

/** The Start node's user-input form. */
export const VarListEditor = ({ value, onChange }) => {
  const rows = Array.isArray(value) ? value : [];
  const update = (i, patch) => onChange(rows.map((r, idx) => (idx === i ? { ...r, ...patch } : r)));

  const TYPES = [
    { value: "text-input", label: "Short text" },
    { value: "paragraph", label: "Paragraph" },
    { value: "select", label: "Select" },
    { value: "number", label: "Number" },
    { value: "file", label: "File" },
    { value: "file-list", label: "File list" },
  ];

  return (
    <div className="space-y-2">
      {rows.map((row, i) => (
        <div key={i} className="rounded-lg border border-slate-200 bg-white p-2.5">
          <div className="mb-2 flex items-center gap-2">
            <input
              value={row.variable ?? ""}
              onChange={(e) => update(i, { variable: e.target.value })}
              placeholder="variable_name"
              className={`${miniCls} flex-1 font-mono`}
            />
            <select
              value={row.type || "text-input"}
              onChange={(e) => update(i, { type: e.target.value })}
              className={miniCls}
            >
              {TYPES.map((t) => (
                <option key={t.value} value={t.value}>
                  {t.label}
                </option>
              ))}
            </select>
            <IconButton
              icon="trash"
              tone="danger"
              title="Remove"
              onClick={() => onChange(rows.filter((_, idx) => idx !== i))}
            />
          </div>
          <input
            value={row.label ?? ""}
            onChange={(e) => update(i, { label: e.target.value })}
            placeholder="Field label shown to the user"
            className={`${miniCls} mb-2 w-full`}
          />
          {row.type === "select" && (
            <input
              value={(row.options || []).join(", ")}
              onChange={(e) =>
                update(i, { options: e.target.value.split(",").map((s) => s.trim()).filter(Boolean) })
              }
              placeholder="Option A, Option B, Option C"
              className={`${miniCls} mb-2 w-full`}
            />
          )}
          <label className="flex items-center gap-2 text-[11px] font-medium text-slate-600">
            <input
              type="checkbox"
              checked={!!row.required}
              onChange={(e) => update(i, { required: e.target.checked })}
              className="rounded border-slate-300"
            />
            Required
          </label>
        </div>
      ))}
      <RowButton
        icon="plus"
        label="Add input field"
        onClick={() =>
          onChange([
            ...rows,
            { variable: `input_${rows.length + 1}`, label: "", type: "text-input", required: false, max_length: 256 },
          ])
        }
      />
    </div>
  );
};

// ---------------------------------------------------------------------------
// Model + prompt
// ---------------------------------------------------------------------------

export const ModelPicker = ({ field, value, onChange }) => {
  const { models } = useDesigner();
  const wanted = field.modelType || "llm";
  const list = models.filter((m) => (m.model_type || "llm") === wanted);
  const current = value || {};
  const key = current.provider && current.name ? `${current.provider}::${current.name}` : "";

  const params = current.completion_params || {};
  const setParam = (k, v) =>
    onChange({ ...current, completion_params: { ...params, [k]: v } });

  return (
    <div className="space-y-2">
      <select
        value={key}
        onChange={(e) => {
          const [provider, name] = e.target.value.split("::");
          const m = list.find((x) => x.provider === provider && x.model === name);
          onChange({
            ...current,
            provider: provider || "",
            name: name || "",
            mode: m?.mode || "chat",
            completion_params: params,
          });
        }}
        className={inputCls}
      >
        <option value="">
          {list.length ? "Select a model…" : "No configured models — add a provider first"}
        </option>
        {list.map((m) => (
          <option key={`${m.provider}::${m.model}`} value={`${m.provider}::${m.model}`}>
            {m.provider_label} · {m.label}
          </option>
        ))}
      </select>

      {key && wanted === "llm" && (
        <div className="rounded-lg border border-slate-200 bg-slate-50 p-2.5">
          <p className="mb-2 text-[10px] font-bold uppercase tracking-wide text-slate-400">
            Completion parameters
          </p>
          <div className="grid grid-cols-2 gap-2">
            {[
              { k: "temperature", label: "Temperature", min: 0, max: 2, step: 0.1 },
              { k: "top_p", label: "Top P", min: 0, max: 1, step: 0.05 },
              { k: "max_tokens", label: "Max tokens", min: 1, max: 128000, step: 1 },
              { k: "presence_penalty", label: "Presence", min: -2, max: 2, step: 0.1 },
            ].map((p) => (
              <label key={p.k} className="block">
                <span className="mb-1 block text-[11px] font-medium text-slate-600">{p.label}</span>
                <input
                  type="number"
                  min={p.min}
                  max={p.max}
                  step={p.step}
                  value={params[p.k] ?? ""}
                  onChange={(e) => setParam(p.k, e.target.value === "" ? undefined : Number(e.target.value))}
                  className={`${miniCls} w-full`}
                />
              </label>
            ))}
          </div>
        </div>
      )}
    </div>
  );
};

/** Role-tagged prompt messages with inline `{{#…#}}` insertion. */
export const PromptEditor = ({ value, onChange }) => {
  const messages = Array.isArray(value) ? value : [{ role: "system", text: "" }];
  const update = (i, patch) =>
    onChange(messages.map((m, idx) => (idx === i ? { ...m, ...patch } : m)));

  return (
    <div className="space-y-2">
      {messages.map((m, i) => (
        <div key={i} className="overflow-hidden rounded-lg border border-slate-200">
          <div className="flex items-center justify-between border-b border-slate-100 bg-slate-50 px-2 py-1.5">
            <select
              value={m.role || "system"}
              onChange={(e) => update(i, { role: e.target.value })}
              className="bg-transparent text-[11px] font-bold uppercase tracking-wide text-slate-500 outline-none"
            >
              {["system", "user", "assistant"].map((r) => (
                <option key={r} value={r}>
                  {r}
                </option>
              ))}
            </select>
            <div className="flex items-center gap-1">
              <VarInsertButton onInsert={(ref) => update(i, { text: `${m.text || ""}${ref}` })} />
              {messages.length > 1 && (
                <IconButton
                  icon="trash"
                  tone="danger"
                  title="Remove message"
                  onClick={() => onChange(messages.filter((_, idx) => idx !== i))}
                />
              )}
            </div>
          </div>
          <textarea
            rows={5}
            value={m.text ?? ""}
            onChange={(e) => update(i, { text: e.target.value })}
            placeholder="Write the prompt. Insert values with {{#node.field#}}."
            className="w-full resize-y px-3 py-2 text-sm text-slate-800 outline-none"
          />
        </div>
      ))}
      <RowButton
        icon="plus"
        label="Add message"
        onClick={() => onChange([...messages, { role: "user", text: "" }])}
      />
    </div>
  );
};

/** Small "insert a variable here" affordance shared by the text editors. */
const VarInsertButton = ({ onInsert }) => {
  const { nodeId, nodes, edges, appMode, envVariables, conversationVariables } = useDesigner();
  const [open, setOpen] = useState(false);
  const groups = useMemo(
    () => availableVariables(nodeId, nodes, edges, { appMode, envVariables, conversationVariables }),
    [nodeId, nodes, edges, appMode, envVariables, conversationVariables],
  );

  return (
    <div className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        title="Insert variable"
        className="flex h-7 items-center gap-1 rounded-lg px-2 text-[11px] font-semibold text-slate-500 transition hover:bg-slate-100 hover:text-blue-600"
      >
        <Icon name="plus" size={12} /> var
      </button>
      {open && (
        <>
          <button
            type="button"
            aria-label="Close"
            className="fixed inset-0 z-10 cursor-default"
            onClick={() => setOpen(false)}
          />
          <div className="absolute right-0 z-20 mt-1 max-h-64 w-64 overflow-y-auto rounded-xl border border-slate-200 bg-white p-2 shadow-xl">
            {groups.length === 0 && <p className="p-2 text-xs text-slate-500">Nothing upstream yet.</p>}
            {groups.map((g) => (
              <div key={`${g.scope}-${g.id}`}>
                <p className="px-2 py-1 text-[10px] font-bold uppercase tracking-wide text-slate-400">
                  {g.title}
                </p>
                {g.variables.map((v) => (
                  <button
                    key={v.ref}
                    type="button"
                    onClick={() => {
                      onInsert(v.ref);
                      setOpen(false);
                    }}
                    className="flex w-full items-center justify-between gap-2 rounded-lg px-2 py-1.5 text-left text-xs transition hover:bg-slate-50"
                  >
                    <span className="truncate text-slate-700">{v.name}</span>
                    {typeChip(v.type)}
                  </button>
                ))}
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  );
};

// ---------------------------------------------------------------------------
// Branching + structured editors
// ---------------------------------------------------------------------------

const operatorsFor = (varType) => {
  if (!varType) return COMPARISON_OPERATORS.string;
  if (String(varType).startsWith("array")) return COMPARISON_OPERATORS.array;
  return COMPARISON_OPERATORS[varType] || COMPARISON_OPERATORS.string;
};

/** No-operand operators — hide the value input for these. */
const UNARY = new Set(["empty", "not empty", "null", "not null", "exists", "not exists"]);

const ConditionRow = ({ condition, onChange, onRemove }) => {
  const ops = operatorsFor(condition.varType);
  return (
    <div className="rounded-lg border border-slate-200 bg-white p-2">
      <div className="mb-1.5 flex items-center gap-2">
        <div className="flex-1">
          <VarPicker
            field={{}}
            value={condition.variable_selector || []}
            onChange={(sel) => onChange({ ...condition, variable_selector: sel })}
          />
        </div>
        <IconButton icon="trash" tone="danger" title="Remove condition" onClick={onRemove} />
      </div>
      <div className="flex items-center gap-2">
        <select
          value={condition.comparison_operator || ops[0]}
          onChange={(e) => onChange({ ...condition, comparison_operator: e.target.value })}
          className={`${miniCls} w-40`}
        >
          {ops.map((o) => (
            <option key={o} value={o}>
              {o}
            </option>
          ))}
        </select>
        {!UNARY.has(condition.comparison_operator) && (
          <input
            value={condition.value ?? ""}
            onChange={(e) => onChange({ ...condition, value: e.target.value })}
            placeholder="value or {{#node.field#}}"
            className={`${miniCls} flex-1`}
          />
        )}
      </div>
    </div>
  );
};

/**
 * The if-else builder. `field.single` collapses it to one flat condition list
 * (used by list-operator's filter and loop's break condition, which have no
 * ELIF concept).
 */
export const ConditionsBuilder = ({ field, value, onChange }) => {
  if (field.single) {
    const conditions = Array.isArray(value) ? value : [];
    return (
      <div className="space-y-2">
        {conditions.map((c, i) => (
          <ConditionRow
            key={c.id || i}
            condition={c}
            onChange={(next) => onChange(conditions.map((x, idx) => (idx === i ? next : x)))}
            onRemove={() => onChange(conditions.filter((_, idx) => idx !== i))}
          />
        ))}
        <RowButton
          icon="plus"
          label="Add condition"
          onClick={() =>
            onChange([...conditions, { id: `c${Date.now()}`, variable_selector: [], comparison_operator: "is", value: "" }])
          }
        />
      </div>
    );
  }

  const cases = Array.isArray(value) && value.length ? value : [{ case_id: "true", logical_operator: "and", conditions: [] }];
  const updateCase = (i, patch) => onChange(cases.map((c, idx) => (idx === i ? { ...c, ...patch } : c)));

  return (
    <div className="space-y-3">
      {cases.map((c, i) => (
        <div key={c.case_id} className="rounded-xl border border-slate-200 bg-slate-50 p-2.5">
          <div className="mb-2 flex items-center justify-between">
            <span className="rounded bg-orange-100 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-orange-700">
              {i === 0 ? "IF" : `ELIF ${i}`}
            </span>
            <div className="flex items-center gap-2">
              {(c.conditions || []).length > 1 && (
                <select
                  value={c.logical_operator || "and"}
                  onChange={(e) => updateCase(i, { logical_operator: e.target.value })}
                  className={miniCls}
                >
                  <option value="and">AND</option>
                  <option value="or">OR</option>
                </select>
              )}
              {cases.length > 1 && (
                <IconButton
                  icon="trash"
                  tone="danger"
                  title="Remove branch"
                  onClick={() => onChange(cases.filter((_, idx) => idx !== i))}
                />
              )}
            </div>
          </div>
          <div className="space-y-2">
            {(c.conditions || []).map((cond, ci) => (
              <ConditionRow
                key={cond.id || ci}
                condition={cond}
                onChange={(next) =>
                  updateCase(i, { conditions: c.conditions.map((x, idx) => (idx === ci ? next : x)) })
                }
                onRemove={() =>
                  updateCase(i, { conditions: c.conditions.filter((_, idx) => idx !== ci) })
                }
              />
            ))}
            <RowButton
              icon="plus"
              label="Add condition"
              onClick={() =>
                updateCase(i, {
                  conditions: [
                    ...(c.conditions || []),
                    { id: `c${Date.now()}`, variable_selector: [], comparison_operator: "is", value: "" },
                  ],
                })
              }
            />
          </div>
        </div>
      ))}
      <RowButton
        icon="plus"
        label="Add ELIF branch"
        onClick={() =>
          onChange([...cases, { case_id: `case-${Date.now()}`, logical_operator: "and", conditions: [] }])
        }
      />
      <p className="text-[11px] text-slate-500">
        Anything not matching a branch above leaves through the ELSE handle.
      </p>
    </div>
  );
};

/** Question-classifier classes — each row grows a source handle on the node. */
export const ClassesEditor = ({ value, onChange }) => {
  const classes = Array.isArray(value) ? value : [];
  return (
    <div className="space-y-2">
      {classes.map((c, i) => (
        <div key={c.id} className="flex items-center gap-2">
          <span className="w-6 shrink-0 text-center text-[11px] font-bold text-slate-400">{i + 1}</span>
          <input
            value={c.name ?? ""}
            onChange={(e) => onChange(classes.map((x, idx) => (idx === i ? { ...x, name: e.target.value } : x)))}
            placeholder="e.g. Billing question"
            className={`${miniCls} flex-1`}
          />
          {classes.length > 2 && (
            <IconButton
              icon="trash"
              tone="danger"
              title="Remove class"
              onClick={() => onChange(classes.filter((_, idx) => idx !== i))}
            />
          )}
        </div>
      ))}
      <RowButton
        icon="plus"
        label="Add class"
        onClick={() => onChange([...classes, { id: `${Date.now()}`, name: "" }])}
      />
    </div>
  );
};

/** Parameter-extractor's typed parameter list. */
export const ParamsEditor = ({ value, onChange }) => {
  const params = Array.isArray(value) ? value : [];
  const update = (i, patch) => onChange(params.map((p, idx) => (idx === i ? { ...p, ...patch } : p)));
  return (
    <div className="space-y-2">
      {params.map((p, i) => (
        <div key={i} className="rounded-lg border border-slate-200 bg-white p-2.5">
          <div className="mb-2 flex items-center gap-2">
            <input
              value={p.name ?? ""}
              onChange={(e) => update(i, { name: e.target.value })}
              placeholder="parameter_name"
              className={`${miniCls} flex-1 font-mono`}
            />
            <select
              value={p.type || "string"}
              onChange={(e) => update(i, { type: e.target.value })}
              className={miniCls}
            >
              {["string", "number", "bool", "select", "array[string]", "array[number]", "array[object]"].map((t) => (
                <option key={t} value={t}>
                  {t}
                </option>
              ))}
            </select>
            <IconButton
              icon="trash"
              tone="danger"
              title="Remove"
              onClick={() => onChange(params.filter((_, idx) => idx !== i))}
            />
          </div>
          <input
            value={p.description ?? ""}
            onChange={(e) => update(i, { description: e.target.value })}
            placeholder="What the model should look for"
            className={`${miniCls} mb-2 w-full`}
          />
          <label className="flex items-center gap-2 text-[11px] font-medium text-slate-600">
            <input
              type="checkbox"
              checked={!!p.required}
              onChange={(e) => update(i, { required: e.target.checked })}
              className="rounded border-slate-300"
            />
            Required
          </label>
        </div>
      ))}
      <RowButton
        icon="plus"
        label="Add parameter"
        onClick={() => onChange([...params, { name: "", type: "string", description: "", required: false }])}
      />
    </div>
  );
};

/**
 * Header/query-param rows. Dify stores these as a newline-delimited
 * `key: value` string, so the editor keeps rows in local state and serialises
 * on every change.
 */
export const KeyValueEditor = ({ value, onChange }) => {
  const rows = String(value || "")
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const idx = line.indexOf(":");
      return idx === -1 ? { k: line, v: "" } : { k: line.slice(0, idx).trim(), v: line.slice(idx + 1).trim() };
    });

  const serialise = (next) =>
    onChange(next.filter((r) => r.k).map((r) => `${r.k}: ${r.v}`).join("\n"));

  return (
    <div className="space-y-1.5">
      {rows.map((r, i) => (
        <div key={i} className="flex items-center gap-2">
          <input
            value={r.k}
            onChange={(e) => serialise(rows.map((x, idx) => (idx === i ? { ...x, k: e.target.value } : x)))}
            placeholder="Header"
            className={`${miniCls} flex-1 font-mono`}
          />
          <input
            value={r.v}
            onChange={(e) => serialise(rows.map((x, idx) => (idx === i ? { ...x, v: e.target.value } : x)))}
            placeholder="value"
            className={`${miniCls} flex-1`}
          />
          <IconButton
            icon="trash"
            tone="danger"
            title="Remove"
            onClick={() => serialise(rows.filter((_, idx) => idx !== i))}
          />
        </div>
      ))}
      <RowButton icon="plus" label="Add row" onClick={() => serialise([...rows, { k: "", v: "" }])} />
    </div>
  );
};

/** Code-node output schema — `{name: {type}}`. */
export const OutputsEditor = ({ value, onChange }) => {
  const entries = Object.entries(value || {});
  const commit = (next) => onChange(Object.fromEntries(next));
  return (
    <div className="space-y-1.5">
      {entries.map(([name, def], i) => (
        <div key={i} className="flex items-center gap-2">
          <input
            value={name}
            onChange={(e) => commit(entries.map((en, idx) => (idx === i ? [e.target.value, en[1]] : en)))}
            placeholder="output_name"
            className={`${miniCls} flex-1 font-mono`}
          />
          <select
            value={def?.type || "string"}
            onChange={(e) => commit(entries.map((en, idx) => (idx === i ? [en[0], { type: e.target.value }] : en)))}
            className={miniCls}
          >
            {VAR_TYPES.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </select>
          <IconButton
            icon="trash"
            tone="danger"
            title="Remove"
            onClick={() => commit(entries.filter((_, idx) => idx !== i))}
          />
        </div>
      ))}
      <RowButton
        icon="plus"
        label="Add output"
        onClick={() => commit([...entries, [`output_${entries.length + 1}`, { type: "string" }]])}
      />
    </div>
  );
};

/** Variable-assigner / loop-variable rows. */
export const AssignmentsEditor = ({ value, onChange }) => {
  const items = Array.isArray(value) ? value : [];
  const update = (i, patch) => onChange(items.map((it, idx) => (idx === i ? { ...it, ...patch } : it)));
  const OPS = ["over-write", "append", "extend", "clear", "set", "+=", "-=", "*=", "/="];
  return (
    <div className="space-y-2">
      {items.map((it, i) => (
        <div key={i} className="rounded-lg border border-slate-200 bg-white p-2">
          <div className="mb-1.5 flex items-center gap-2">
            <div className="flex-1">
              <VarPicker
                field={{}}
                value={it.variable_selector || []}
                onChange={(sel) => update(i, { variable_selector: sel })}
              />
            </div>
            <IconButton
              icon="trash"
              tone="danger"
              title="Remove"
              onClick={() => onChange(items.filter((_, idx) => idx !== i))}
            />
          </div>
          <div className="flex items-center gap-2">
            <select
              value={it.operation || "over-write"}
              onChange={(e) => update(i, { operation: e.target.value })}
              className={`${miniCls} w-32`}
            >
              {OPS.map((o) => (
                <option key={o} value={o}>
                  {o}
                </option>
              ))}
            </select>
            {it.operation !== "clear" && (
              <input
                value={it.value ?? ""}
                onChange={(e) => update(i, { value: e.target.value })}
                placeholder="value or {{#node.field#}}"
                className={`${miniCls} flex-1`}
              />
            )}
          </div>
        </div>
      ))}
      <RowButton
        icon="plus"
        label="Add assignment"
        onClick={() => onChange([...items, { variable_selector: [], operation: "over-write", value: "" }])}
      />
    </div>
  );
};

/** Tool provider + action picker, writing the flat shape the tool node stores. */
export const ToolPicker = ({ field, value, onChange, data }) => {
  const { toolProviders } = useDesigner();
  const multiple = !!field.multiple;

  if (multiple) {
    const selected = Array.isArray(value) ? value : [];
    const toggle = (provider, tool) => {
      const key = `${provider.id}::${tool.name}`;
      const exists = selected.some((s) => `${s.provider_id}::${s.tool_name}` === key);
      onChange(
        exists
          ? selected.filter((s) => `${s.provider_id}::${s.tool_name}` !== key)
          : [
              ...selected,
              {
                provider_id: provider.id,
                provider_type: provider.type,
                provider_name: provider.name,
                tool_name: tool.name,
                tool_label: tool.label,
                enabled: true,
              },
            ],
      );
    };
    return (
      <div className="space-y-2">
        {toolProviders.map((p) => (
          <div key={p.id} className="rounded-lg border border-slate-200 bg-white p-2">
            <p className="mb-1.5 text-[11px] font-bold uppercase tracking-wide text-slate-400">{p.name}</p>
            {p.tools.map((t) => {
              const on = selected.some((s) => s.provider_id === p.id && s.tool_name === t.name);
              return (
                <label key={t.name} className="flex items-center gap-2 py-1 text-xs text-slate-700">
                  <input
                    type="checkbox"
                    checked={on}
                    onChange={() => toggle(p, t)}
                    className="rounded border-slate-300"
                  />
                  {t.label}
                </label>
              );
            })}
          </div>
        ))}
        {toolProviders.length === 0 && (
          <p className="text-xs text-slate-500">No tool providers installed.</p>
        )}
      </div>
    );
  }

  // Single-tool form: the `tool` node stores provider/tool at the data root.
  const provider = toolProviders.find((p) => p.id === data?.provider_id);
  const tool = provider?.tools.find((t) => t.name === data?.tool_name);
  const key = data?.provider_id && data?.tool_name ? `${data.provider_id}::${data.tool_name}` : "";

  return (
    <div className="space-y-2">
      <select
        value={key}
        onChange={(e) => {
          const [pid, tname] = e.target.value.split("::");
          const p = toolProviders.find((x) => x.id === pid);
          const t = p?.tools.find((x) => x.name === tname);
          onChange({
            provider_id: pid || "",
            provider_type: p?.type || "builtin",
            provider_name: p?.name || "",
            tool_name: tname || "",
            tool_label: t?.label || "",
            tool_parameters: {},
            tool_configurations: {},
          });
        }}
        className={inputCls}
      >
        <option value="">Select a tool…</option>
        {toolProviders.map((p) => (
          <optgroup key={p.id} label={p.name}>
            {p.tools.map((t) => (
              <option key={t.name} value={`${p.id}::${t.name}`}>
                {t.label}
              </option>
            ))}
          </optgroup>
        ))}
      </select>

      {provider && !provider.team_credentials_configured && (
        <p className="rounded-lg bg-amber-50 px-2.5 py-2 text-[11px] font-medium text-amber-800">
          {provider.name} has no credentials configured — runs will fail until it does.
        </p>
      )}

      {tool && (
        <div className="rounded-lg border border-slate-200 bg-slate-50 p-2.5">
          <p className="mb-2 text-[10px] font-bold uppercase tracking-wide text-slate-400">
            Tool parameters
          </p>
          <div className="space-y-2">
            {tool.parameters.map((param) => (
              <div key={param.name}>
                <label className="mb-1 flex items-center gap-1.5 text-[11px] font-semibold text-slate-600">
                  {param.label}
                  {param.required && <span className="text-red-500">*</span>}
                  <span className="rounded bg-slate-200 px-1 py-0.5 text-[9px] font-bold uppercase text-slate-500">
                    {param.form === "llm" ? "model decides" : "fixed"}
                  </span>
                </label>
                {param.type === "select" ? (
                  <select
                    value={data?.tool_parameters?.[param.name]?.value ?? ""}
                    onChange={(e) =>
                      onChange({
                        ...data,
                        tool_parameters: {
                          ...(data?.tool_parameters || {}),
                          [param.name]: { type: "mixed", value: e.target.value },
                        },
                      })
                    }
                    className={`${miniCls} w-full`}
                  >
                    <option value="">—</option>
                    {(param.options || []).map((o) => (
                      <option key={o} value={o}>
                        {o}
                      </option>
                    ))}
                  </select>
                ) : (
                  <input
                    value={data?.tool_parameters?.[param.name]?.value ?? ""}
                    onChange={(e) =>
                      onChange({
                        ...data,
                        tool_parameters: {
                          ...(data?.tool_parameters || {}),
                          [param.name]: { type: "mixed", value: e.target.value },
                        },
                      })
                    }
                    placeholder={param.form === "llm" ? "leave blank to let the model fill it" : "value or {{#node.field#}}"}
                    className={`${miniCls} w-full`}
                  />
                )}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
};

export const DatasetPicker = ({ value, onChange }) => {
  const { datasets } = useDesigner();
  const selected = Array.isArray(value) ? value : [];
  return (
    <div className="space-y-1.5">
      {datasets.map((d) => {
        const on = selected.includes(d.id);
        return (
          <label
            key={d.id}
            className={`flex cursor-pointer items-center justify-between gap-2 rounded-lg border p-2.5 transition ${
              on ? "border-blue-500 bg-blue-50" : "border-slate-200 bg-white hover:border-slate-300"
            }`}
          >
            <div className="min-w-0">
              <p className="truncate text-xs font-semibold text-slate-800">{d.name}</p>
              <p className="text-[11px] text-slate-500">
                {d.document_count} docs · {d.indexing_technique === "high_quality" ? "High quality" : "Economy"}
              </p>
            </div>
            <input
              type="checkbox"
              checked={on}
              onChange={() => onChange(on ? selected.filter((x) => x !== d.id) : [...selected, d.id])}
              className="rounded border-slate-300"
            />
          </label>
        );
      })}
      {datasets.length === 0 && <p className="text-xs text-slate-500">No knowledge bases yet.</p>}
    </div>
  );
};

// ---------------------------------------------------------------------------
// Registry consumed by the panel's generic renderer.
// ---------------------------------------------------------------------------

export const FIELD_COMPONENTS = {
  text: TextField,
  textarea: TextareaField,
  number: NumberField,
  switch: SwitchField,
  select: SelectField,
  code: CodeField,
  json: JsonField,
  model: ModelPicker,
  prompt: PromptEditor,
  var: VarPicker,
  vars: VarsEditor,
  varlist: VarListEditor,
  conditions: ConditionsBuilder,
  classes: ClassesEditor,
  params: ParamsEditor,
  keyvalue: KeyValueEditor,
  outputs: OutputsEditor,
  assignments: AssignmentsEditor,
  tool: ToolPicker,
  datasets: DatasetPicker,
};
