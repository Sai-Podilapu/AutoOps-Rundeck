import React, { useEffect, useMemo, useState } from "react";
import ModalPortal from "./ModalPortal";
import Icon from "../Icon";

const inputCls =
  "w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-violet-400 focus:ring-2 focus:ring-violet-400/20 hover:border-blue-500";

/**
 * The form a workflow asks for before it runs.
 *
 * <p>Generated from the schema the workflow itself publishes — never from
 * anything typed into AutoOps. That matters because the schema is read live
 * from the engine at open time: a variable the provider adds in the designer
 * appears here on the next run, and cannot silently diverge from what the
 * workflow actually reads.
 *
 * <p>Required fields are enforced here AND on the server. The client check
 * exists to avoid a pointless round trip, not to be the gate — a run posted
 * straight at the API is validated the same way.
 *
 * @param fields  [{variable, label, type, required, defaultValue, options, maxLength}]
 */
export default function RunInputsDialog({ title, fields, busy, onCancel, onRun }) {
  const requiredCount = fields.filter((f) => f.required).length;
  const optionalCount = fields.length - requiredCount;
  // Seeded from the schema's defaults, so a form of all-optional fields with
  // sensible defaults is one Enter away from running.
  const initial = useMemo(() => {
    const seed = {};
    for (const f of fields) seed[f.variable] = f.defaultValue ?? "";
    return seed;
  }, [fields]);

  const [values, setValues] = useState(initial);
  const [touched, setTouched] = useState(false);

  useEffect(() => setValues(initial), [initial]);

  useEffect(() => {
    const onKey = (e) => e.key === "Escape" && !busy && onCancel();
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [busy, onCancel]);

  const missing = fields.filter(
    (f) => f.required && String(values[f.variable] ?? "").trim() === "",
  );

  const submit = (e) => {
    e.preventDefault();
    setTouched(true);
    if (missing.length || busy) return;
    // Blank optionals are dropped rather than sent as "": an absent key lets
    // the workflow's own default apply, while "" overrides it with emptiness.
    const payload = {};
    for (const f of fields) {
      const v = values[f.variable];
      if (v !== undefined && String(v).trim() !== "") payload[f.variable] = v;
    }
    onRun(payload);
  };

  const field = (f) => {
    const value = values[f.variable] ?? "";
    const set = (v) => setValues((s) => ({ ...s, [f.variable]: v }));
    const invalid = touched && f.required && String(value).trim() === "";
    const cls = `${inputCls} ${invalid ? "border-red-400" : ""}`;
    // The id ties the <label> to the control. Without it the label is decoration:
    // clicking it does not focus the field, and a screen reader announces an
    // unnamed input.
    const id = `run-input-${f.variable}`;
    const common = {
      id,
      className: cls,
      value,
      "aria-required": f.required || undefined,
      "aria-invalid": invalid || undefined,
      onChange: (e) => set(e.target.value),
    };
    if (f.type === "select") {
      return (
        <select {...common}>
          <option value="">Choose…</option>
          {(f.options || []).map((o) => (
            <option key={o} value={o}>
              {o}
            </option>
          ))}
        </select>
      );
    }
    if (f.type === "paragraph") {
      return (
        <textarea
          {...common}
          rows={4}
          className={`${cls} resize-none`}
          maxLength={f.maxLength || undefined}
        />
      );
    }
    return (
      <input
        {...common}
        type={f.type === "number" ? "number" : "text"}
        maxLength={f.type === "number" ? undefined : f.maxLength || undefined}
      />
    );
  };

  return (
    <ModalPortal onClose={busy ? undefined : onCancel}>
      <form
        onSubmit={submit}
        role="dialog"
        aria-modal="true"
        aria-label={`Run ${title}`}
        className="rw-pop relative flex w-full max-w-lg flex-col overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-2xl"
        style={{ maxHeight: "min(680px, calc(100vh - 4rem))" }}
      >
        <div className="border-b border-slate-200 px-6 py-4">
          <h2 className="text-base font-semibold text-slate-900">Run “{title}”</h2>
          {/* Required and optional counted separately: "11 values" reads as
              eleven things you must find answers for, when five are mandatory
              and the rest have sane defaults or can be left alone. */}
          <p className="mt-0.5 text-xs text-slate-500">
            {requiredCount === 0
              ? `${fields.length} optional value${fields.length === 1 ? "" : "s"} — run it as-is or adjust below.`
              : optionalCount === 0
                ? `${requiredCount} value${requiredCount === 1 ? "" : "s"} needed before it starts.`
                : `${requiredCount} required, ${optionalCount} optional.`}
          </p>
        </div>

        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto px-6 py-5">
          {fields.map((f) => (
            <div key={f.variable}>
              <label
                htmlFor={`run-input-${f.variable}`}
                className="mb-1.5 block text-xs font-semibold text-slate-700"
              >
                {f.label || f.variable}
                {f.required && <span className="ml-1 text-red-500">*</span>}
              </label>
              {field(f)}
            </div>
          ))}
        </div>

        <div className="flex items-center justify-between gap-3 border-t border-slate-200 px-6 py-4">
          <p className="text-xs text-red-600">
            {touched && missing.length
              ? `Fill in: ${missing.map((f) => f.label || f.variable).join(", ")}`
              : ""}
          </p>
          <div className="flex shrink-0 gap-2">
            <button
              type="button"
              onClick={onCancel}
              disabled={busy}
              className="rounded-lg border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-900 transition hover:border-blue-600 hover:bg-blue-600 hover:text-white disabled:opacity-40"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={busy}
              className="inline-flex items-center gap-1.5 rounded-lg bg-blue-600 px-4 py-2 text-sm font-semibold text-white shadow-lg shadow-blue-600/40 transition hover:bg-blue-700 disabled:opacity-40"
            >
              <Icon name="play" size={15} /> {busy ? "Starting…" : "Run"}
            </button>
          </div>
        </div>
      </form>
    </ModalPortal>
  );
}
