import React, { useEffect, useState } from "react";
import { createPortal } from "react-dom";

// Lightweight create/edit modal driven by a fields config.
//
// fields: [{ name, label, placeholder?, help?,
//            type?: "text"|"textarea"|"select"|"password",
//            required?, options?: [{value,label}], when?: (values) => boolean }]
//
// `when` makes a field conditional on what has been picked so far, so a form
// covering several shapes shows only the fields for the chosen one instead of
// listing them all and naming the applicable kind in the label. A hidden
// field's value is dropped on submit — switching type after typing must not
// smuggle the abandoned value through.
export default function FormModal({
  open,
  title,
  description,
  fields = [],
  submitLabel = "Create",
  busy = false,
  error = null,
  onSubmit,
  onClose,
}) {
  const [values, setValues] = useState({});

  useEffect(() => {
    if (open) {
      const init = {};
      fields.forEach((f) => {
        // A required select has no blank option, so the browser displays its
        // first entry. Seeding state to "" would show one thing and submit
        // another — silently omitting the field the form looks like it set.
        init[f.name] =
          f.defaultValue ??
          (f.type === "select" && f.required ? (f.options?.[0]?.value ?? "") : "");
      });
      setValues(init);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  if (!open) return null;

  const visibleFields = fields.filter((f) => !f.when || f.when(values));

  const set = (k, v) => setValues((s) => ({ ...s, [k]: v }));
  const submit = (e) => {
    e.preventDefault();
    if (busy) return;
    const shown = new Set(visibleFields.map((f) => f.name));
    const cleaned = {};
    Object.keys(values).forEach((k) => {
      if (!shown.has(k)) return;
      const v = typeof values[k] === "string" ? values[k].trim() : values[k];
      if (v !== "" && v !== undefined && v !== null) cleaned[k] = v;
    });
    onSubmit(cleaned);
  };

  // Password managers ignore autocomplete="off" but honour these.
  const noAutofill = {
    autoCorrect: "off",
    spellCheck: false,
    "data-lpignore": "true",
    "data-1p-ignore": "true",
    "data-form-type": "other",
  };

  const inputCls =
    "w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-violet-400 focus:ring-2 focus:ring-violet-400/20 hover:border-blue-500";

  return createPortal(
    <div className="fixed inset-0 z-[95] flex items-center justify-center p-4">
      {/* Backdrop — same scrim as every other dialog (see ModalPortal). */}
      <div
        className="absolute inset-0 bg-slate-900/25 backdrop-blur-md"
        onClick={busy ? undefined : onClose}
      />

      {/* Modal */}
      <form
        onSubmit={submit}
        autoComplete="off"
        className="relative flex w-full max-w-sm flex-col overflow-hidden rounded-xl bg-white shadow-xl ring-1 ring-slate-200/80 animate-fade-up" style={{maxHeight: 'calc(100vh - 2rem)'}}
      >
        {/* Header */}
        <div className="shrink-0 border-b border-slate-100 bg-gradient-to-br from-slate-50 to-white px-4 py-3.5">
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0 flex-1">
              <h3 className="truncate text-[15px] font-semibold text-slate-900 leading-snug">
                {title}
              </h3>
              {description && (
                <p className="mt-0.5 text-xs text-slate-500 leading-relaxed line-clamp-2">
                  {description}
                </p>
              )}
            </div>
            <button
              type="button"
              onClick={onClose}
              disabled={busy}
              className="flex h-7 w-7 shrink-0 items-center justify-center rounded-lg text-slate-400 transition hover:bg-slate-100 hover:text-slate-600 disabled:opacity-50"
            >
              <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2.5"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <path d="M18 6 6 18" />
                <path d="m6 6 12 12" />
              </svg>
            </button>
          </div>
        </div>

        {/* Body */}
        <div className="flex-1 overflow-y-auto px-4 py-4">
          <div className="space-y-4">
            {/* `key` falls back to the name, but two mutually-exclusive
                variants of one field (same name, different `when`) need
                distinct keys or React reuses the wrong node. */}
            {visibleFields.map((f) => (
              <div key={f.key || f.name}>
                <label
                  htmlFor={`autoops-${f.name}`}
                  className="mb-1.5 block text-xs font-semibold text-slate-700"
                >
                  {f.label}{" "}
                  {f.required && <span className="text-violet-500">*</span>}
                </label>
                {f.type === "textarea" ? (
                  <textarea
                    id={`autoops-${f.name}`}
                    name={`autoops-${f.name}`}
                    rows={f.rows || 3}
                    placeholder={f.placeholder}
                    required={f.required}
                    disabled={busy}
                    value={values[f.name] || ""}
                    onChange={(e) => set(f.name, e.target.value)}
                    className={`${inputCls} resize-none`}
                    {...noAutofill}
                  />
                ) : f.type === "select" ? (
                  <select
                    id={`autoops-${f.name}`}
                    name={`autoops-${f.name}`}
                    required={f.required}
                    disabled={busy}
                    value={values[f.name] || ""}
                    onChange={(e) => set(f.name, e.target.value)}
                    className={inputCls}
                  >
                    {!f.required && (
                      <option value="">{f.placeholder || "Select..."}</option>
                    )}
                    {f.options?.map((opt) => (
                      <option key={opt.value} value={opt.value}>
                        {opt.label}
                      </option>
                    ))}
                  </select>
                ) : (
                  <input
                    id={`autoops-${f.name}`}
                    // Chrome matches saved credentials on the input's `name`,
                    // so a field called "repo" next to a password field gets
                    // the account email poured into it. A synthetic name plus
                    // new-password stops the browser recognising this as a
                    // sign-in form and filling a token it was never given.
                    name={`autoops-${f.name}`}
                    type={f.type || "text"}
                    placeholder={f.placeholder}
                    required={f.required}
                    disabled={busy}
                    value={values[f.name] || ""}
                    onChange={(e) => set(f.name, e.target.value)}
                    className={inputCls}
                    autoComplete={f.type === "password" ? "new-password" : "off"}
                    {...noAutofill}
                  />
                )}
                {f.help && (
                  <p className="mt-1 text-[11px] leading-relaxed text-slate-500">
                    {f.help}
                  </p>
                )}
              </div>
            ))}
            {error && (
              <div className="rounded-lg bg-red-50 p-3">
                <p className="text-xs font-medium text-red-600">{error}</p>
              </div>
            )}
          </div>
        </div>

        {/* Footer */}
        <div className="shrink-0 border-t border-slate-100 bg-slate-50/50 px-4 py-3.5">
          <div className="flex justify-end gap-2">
            <button
              type="button"
              onClick={onClose}
              disabled={busy}
              className="rounded-lg px-3.5 py-2 text-sm font-medium text-slate-600 transition hover:bg-slate-100 disabled:opacity-50"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={busy}
              className="relative inline-flex items-center justify-center rounded-lg bg-slate-900 px-4 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-slate-800 disabled:opacity-70"
            >
              <span className={busy ? "opacity-0" : ""}>{submitLabel}</span>
              {busy && (
                <div className="absolute inset-0 flex items-center justify-center">
                  <svg
                    className="h-4 w-4 animate-spin text-white"
                    xmlns="http://www.w3.org/2000/svg"
                    fill="none"
                    viewBox="0 0 24 24"
                  >
                    <circle
                      className="opacity-25"
                      cx="12"
                      cy="12"
                      r="10"
                      stroke="currentColor"
                      strokeWidth="4"
                    ></circle>
                    <path
                      className="opacity-75"
                      fill="currentColor"
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                    ></path>
                  </svg>
                </div>
              )}
            </button>
          </div>
        </div>
      </form>
    </div>,
    document.body
  );
}
