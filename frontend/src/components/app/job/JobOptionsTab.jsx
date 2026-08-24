import React, { useState } from "react";
import { Card, Chip, SmallButton } from "../appui";
import Icon from "../../Icon";

const inputCls =
  "w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300";

const label = "mb-1.5 block text-xs font-medium text-slate-500";

// Rundeck's four input presentations, kept name-for-name so an imported job
// round-trips and an operator who knows Rundeck recognises the screen.
const INPUT_TYPES = [
  {
    id: "plain",
    label: "Plain Text",
    hint: "A normal value, shown as typed.",
  },
  {
    id: "date",
    label: "Date",
    hint: "Passed to the job as a formatted date string.",
  },
  {
    id: "password",
    label: "Password",
    hint: "Masked on entry. The value IS available to scripts and commands.",
  },
  {
    id: "secure",
    label: "Secure (auth only)",
    // The distinction that matters and is easy to miss: this one never reaches
    // a script, so it cannot leak through a step's own output.
    hint: "Masked, never stored, and never exposed to scripts — used only to authenticate to nodes.",
  },
];

const blankOption = () => ({
  name: "",
  label: "",
  description: "",
  defaultValue: "",
  inputType: "plain",
  valuesSource: "list",
  values: "",
  valuesUrl: "",
  delimiter: ",",
  sortValues: false,
  restriction: "none",
  regex: "",
  required: false,
  hidden: false,
  multivalued: false,
});

const Radio = ({ name, value, current, onChange, children }) => (
  <label className="flex cursor-pointer items-start gap-2 text-sm text-slate-700">
    <input
      type="radio"
      name={name}
      checked={current === value}
      onChange={() => onChange(value)}
      className="mt-0.5 h-4 w-4 accent-blue-600"
    />
    <span>{children}</span>
  </label>
);

const Toggle = ({ checked, onChange, children, help }) => (
  <div>
    <label className="flex cursor-pointer items-center gap-2 text-sm text-slate-700">
      <input
        type="checkbox"
        checked={!!checked}
        onChange={(e) => onChange(e.target.checked)}
        className="h-4 w-4 rounded accent-blue-600"
      />
      {children}
    </label>
    {help && <p className="mt-1 text-[11px] leading-relaxed text-slate-500">{help}</p>}
  </div>
);

/**
 * Job options — the parameters an operator fills in at run time.
 *
 * Every control here maps onto something the run form and the executor already
 * understand, so an option is not decoration: `required` blocks a run with a
 * blank value, `restriction` bounds what may be submitted, and a `secure`
 * option is withheld from the audit receipt rather than merely masked on screen.
 */
export default function JobOptionsTab({ options, onChange }) {
  const [editing, setEditing] = useState(null);
  const [draft, setDraft] = useState(blankOption());

  const set = (field, value) => setDraft((d) => ({ ...d, [field]: value }));

  const startAdd = () => {
    setDraft(blankOption());
    setEditing("new");
  };
  const startEdit = (index) => {
    setDraft({ ...blankOption(), ...options[index] });
    setEditing(index);
  };
  const cancel = () => setEditing(null);

  const commit = () => {
    const name = draft.name.trim();
    if (!name) return;
    const next = [...options];
    if (editing === "new") {
      next.push({ ...draft, name });
    } else {
      next[editing] = { ...draft, name };
    }
    onChange(next);
    setEditing(null);
  };

  const remove = (index) => onChange(options.filter((_, i) => i !== index));

  const move = (index, delta) => {
    const target = index + delta;
    if (target < 0 || target >= options.length) return;
    const next = [...options];
    [next[index], next[target]] = [next[target], next[index]];
    onChange(next);
  };

  const nameTaken =
    draft.name.trim() &&
    options.some(
      (o, i) =>
        o.name.toLowerCase() === draft.name.trim().toLowerCase() && i !== editing,
    );

  return (
    <div className="space-y-5">
      <Card className="p-6">
        <div className="mb-4 flex items-center justify-between">
          <div>
            <h3 className="text-sm font-semibold text-slate-900">Options</h3>
            <p className="mt-0.5 text-xs text-slate-500">
              Values an operator supplies when the job runs. Reference one in a step
              as{" "}
              <code className="rounded bg-slate-100 px-1 py-0.5 font-mono text-[11px]">
                {"{{optionName}}"}
              </code>
              .
            </p>
          </div>
          <SmallButton icon="plus" variant="primary" onClick={startAdd}>
            Add option
          </SmallButton>
        </div>

        {options.length === 0 && editing === null && (
          <div className="rounded-lg border border-dashed border-slate-200 px-5 py-10 text-center text-sm text-slate-500">
            No options. This job runs with no operator input.
          </div>
        )}

        {options.length > 0 && (
          <div className="space-y-2">
            {options.map((o, i) => (
              <div
                key={`${o.name}-${i}`}
                className="flex items-center gap-3 rounded-lg border border-slate-200 bg-slate-50 px-4 py-3"
              >
                <span className="font-mono text-sm font-medium text-slate-900">
                  {o.name}
                </span>
                {o.required && <Chip>required</Chip>}
                {(o.inputType === "secure" || o.inputType === "password") && (
                  <Chip>{o.inputType === "secure" ? "auth only" : "masked"}</Chip>
                )}
                {o.multivalued && <Chip>multi</Chip>}
                {o.restriction === "enforced" && <Chip>enforced</Chip>}
                <span className="min-w-0 flex-1 truncate text-xs text-slate-500">
                  {o.description || o.label || ""}
                </span>
                <div className="flex shrink-0 items-center gap-1">
                  <button
                    onClick={() => move(i, -1)}
                    disabled={i === 0}
                    aria-label="Move up"
                    className="rounded p-1 text-slate-400 transition hover:bg-slate-200 hover:text-slate-700 disabled:opacity-30"
                  >
                    <Icon name="chevron" size={14} />
                  </button>
                  <SmallButton icon="pencil" onClick={() => startEdit(i)}>
                    Edit
                  </SmallButton>
                  <button
                    onClick={() => remove(i)}
                    aria-label={`Remove option ${o.name}`}
                    className="rounded-lg border border-slate-200 bg-white px-2.5 py-2 text-slate-500 transition hover:border-red-500 hover:bg-red-500 hover:text-white"
                  >
                    <Icon name="trash" size={14} />
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}
      </Card>

      {editing !== null && (
        <Card className="p-6">
          <h3 className="mb-5 text-sm font-semibold text-slate-900">
            {editing === "new" ? "Add option" : `Edit option`}
          </h3>

          <div className="grid gap-5 md:grid-cols-2">
            <div>
              <label className={label}>Name *</label>
              <input
                value={draft.name}
                onChange={(e) => set("name", e.target.value)}
                placeholder="environment"
                className={inputCls}
              />
              <p className="mt-1 text-[11px] text-slate-500">
                Referenced in steps as{" "}
                <code className="font-mono">
                  {`{{${draft.name || "name"}}}`}
                </code>
              </p>
              {nameTaken && (
                <p className="mt-1 text-[11px] font-medium text-red-600">
                  Another option already uses this name.
                </p>
              )}
            </div>
            <div>
              <label className={label}>Label</label>
              <input
                value={draft.label}
                onChange={(e) => set("label", e.target.value)}
                placeholder="Target environment"
                className={inputCls}
              />
              <p className="mt-1 text-[11px] text-slate-500">
                Shown on the run form instead of the name.
              </p>
            </div>
          </div>

          <div className="mt-5">
            <label className={label}>Description</label>
            <textarea
              rows={2}
              value={draft.description}
              onChange={(e) => set("description", e.target.value)}
              placeholder="What this value controls…"
              className={`${inputCls} resize-none`}
            />
          </div>

          <div className="mt-5 grid gap-5 md:grid-cols-2">
            <div>
              <label className={label}>Default value</label>
              <input
                value={draft.defaultValue}
                onChange={(e) => set("defaultValue", e.target.value)}
                className={inputCls}
                // A default on a secure option would be a credential stored in
                // the job definition, which is the thing "secure" exists to
                // prevent.
                disabled={draft.inputType === "secure"}
                placeholder={
                  draft.inputType === "secure"
                    ? "Not available for auth-only options"
                    : ""
                }
              />
            </div>
            <div>
              <label className={label}>Input type</label>
              <div className="space-y-2 rounded-lg border border-slate-200 bg-slate-50 p-3">
                {INPUT_TYPES.map((t) => (
                  <div key={t.id}>
                    <Radio
                      name="inputType"
                      value={t.id}
                      current={draft.inputType}
                      onChange={(v) => set("inputType", v)}
                    >
                      <span className="font-medium">{t.label}</span>
                    </Radio>
                    <p className="ml-6 text-[11px] leading-relaxed text-slate-500">
                      {t.hint}
                    </p>
                  </div>
                ))}
              </div>
            </div>
          </div>

          {/* Allowed values — hidden for secure options, which have none. */}
          {draft.inputType !== "secure" && (
            <div className="mt-5 rounded-lg border border-slate-200 p-4">
              <p className="mb-3 text-xs font-semibold text-slate-700">
                Allowed values
              </p>
              <div className="flex flex-wrap gap-5">
                <Radio
                  name="valuesSource"
                  value="list"
                  current={draft.valuesSource}
                  onChange={(v) => set("valuesSource", v)}
                >
                  List
                </Radio>
                <Radio
                  name="valuesSource"
                  value="url"
                  current={draft.valuesSource}
                  onChange={(v) => set("valuesSource", v)}
                >
                  Remote URL
                </Radio>
              </div>

              {draft.valuesSource === "list" ? (
                <div className="mt-3 grid gap-4 md:grid-cols-[1fr_140px]">
                  <div>
                    <input
                      value={draft.values}
                      onChange={(e) => set("values", e.target.value)}
                      placeholder="staging,production"
                      className={inputCls}
                    />
                    <p className="mt-1 text-[11px] text-slate-500">
                      Separated by the delimiter below.
                    </p>
                  </div>
                  <div>
                    <input
                      value={draft.delimiter}
                      onChange={(e) => set("delimiter", e.target.value)}
                      placeholder=","
                      className={inputCls}
                    />
                    <p className="mt-1 text-[11px] text-slate-500">Delimiter</p>
                  </div>
                </div>
              ) : (
                <div className="mt-3">
                  <input
                    value={draft.valuesUrl}
                    onChange={(e) => set("valuesUrl", e.target.value)}
                    placeholder="https://api.example.com/environments"
                    className={inputCls}
                  />
                  <p className="mt-1 text-[11px] text-slate-500">
                    Must return a JSON array of strings, or of{" "}
                    <code className="font-mono">{`{name, value}`}</code> objects.
                  </p>
                </div>
              )}

              <div className="mt-3">
                <Toggle
                  checked={draft.sortValues}
                  onChange={(v) => set("sortValues", v)}
                >
                  Sort the list
                </Toggle>
              </div>
            </div>
          )}

          <div className="mt-5 rounded-lg border border-slate-200 p-4">
            <p className="mb-3 text-xs font-semibold text-slate-700">Restrictions</p>
            <div className="space-y-2">
              <Radio
                name="restriction"
                value="none"
                current={draft.restriction}
                onChange={(v) => set("restriction", v)}
              >
                None — any value may be used
              </Radio>
              <Radio
                name="restriction"
                value="enforced"
                current={draft.restriction}
                onChange={(v) => set("restriction", v)}
              >
                Enforced — must be one of the allowed values
              </Radio>
              <Radio
                name="restriction"
                value="regex"
                current={draft.restriction}
                onChange={(v) => set("restriction", v)}
              >
                Must match a regular expression
              </Radio>
            </div>
            {draft.restriction === "regex" && (
              <input
                value={draft.regex}
                onChange={(e) => set("regex", e.target.value)}
                placeholder="^(eu|us)-[a-z]+-\d$"
                className={`${inputCls} mt-3 font-mono`}
              />
            )}
          </div>

          <div className="mt-5 grid gap-4 md:grid-cols-3">
            <Toggle
              checked={draft.required}
              onChange={(v) => set("required", v)}
              help="The run is refused if this is left blank."
            >
              Required
            </Toggle>
            <Toggle
              checked={draft.hidden}
              onChange={(v) => set("hidden", v)}
              help="Kept off the run form; the default value is used."
            >
              Hidden
            </Toggle>
            <Toggle
              checked={draft.multivalued}
              onChange={(v) => set("multivalued", v)}
              help="Several values may be chosen at once."
            >
              Multi-valued
            </Toggle>
          </div>

          <div className="mt-6 flex justify-end gap-2">
            <SmallButton onClick={cancel}>Cancel</SmallButton>
            <SmallButton
              variant="primary"
              onClick={commit}
              disabled={!draft.name.trim() || !!nameTaken}
            >
              {editing === "new" ? "Add option" : "Save option"}
            </SmallButton>
          </div>
        </Card>
      )}
    </div>
  );
}
