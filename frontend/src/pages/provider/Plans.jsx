import React, { useEffect, useState } from "react";
import { PageHeader, Card, SmallButton } from "../../components/app/appui";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";

const money = (n) => `$${Number(n || 0).toLocaleString()}`;

const LIMIT_FIELDS = [
  ["maxProjects", "Max projects"],
  ["maxAutomations", "Max automations"],
  ["maxNodes", "Max nodes"],
  ["maxJobs", "Max jobs"],
  ["maxCloudIntegrations", "Cloud integrations"],
  ["historyDays", "History (days)"],
];

const fieldCls =
  "w-full rounded-lg border border-slate-200 bg-white px-2.5 py-1.5 text-sm text-slate-900 outline-none transition focus:border-violet-400 focus:ring-2 focus:ring-violet-400/15";

export default function Plans() {
  const { pushToast } = useStore();
  const [plans, setPlans] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [editing, setEditing] = useState(null); // plan code being edited
  const [form, setForm] = useState({});
  const [busy, setBusy] = useState(false);

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const list = await api.listPlans();
      setPlans(Array.isArray(list) ? list : []);
    } catch (err) {
      setError(err.message || "Could not load plans");
    } finally {
      setLoading(false);
    }
  };
  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const startEdit = (p) => {
    setEditing(p.code);
    setForm({
      priceMonthly: p.priceMonthly ?? "",
      description: p.description ?? "",
      maxProjects: p.maxProjects ?? "",
      maxAutomations: p.maxAutomations ?? "",
      maxNodes: p.maxNodes ?? "",
      maxJobs: p.maxJobs ?? "",
      maxCloudIntegrations: p.maxCloudIntegrations ?? "",
      historyDays: p.historyDays ?? "",
      active: p.active ?? true,
    });
  };

  const set = (k, v) => setForm((s) => ({ ...s, [k]: v }));

  const save = async (code) => {
    setBusy(true);
    try {
      const body = { active: !!form.active };
      if (String(form.description).trim() !== "")
        body.description = String(form.description).trim();
      [
        "priceMonthly",
        "maxProjects",
        "maxAutomations",
        "maxNodes",
        "maxJobs",
        "maxCloudIntegrations",
        "historyDays",
      ].forEach((k) => {
        const n = Number(form[k]);
        if (form[k] !== "" && Number.isFinite(n)) body[k] = n;
      });
      await api.providerUpdatePlan(code, body);
      pushToast(`Plan ${code} updated`, "emerald");
      setEditing(null);
      await load();
    } catch (err) {
      pushToast(err.message || `Could not update plan ${code}`, "red");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Plans & Quotas"
        subtitle="The fixed plan catalog your customers subscribe to — edit pricing and limits"
      />

      {loading ? (
        <p className="text-sm text-slate-500">Loading plans…</p>
      ) : error ? (
        <Card className="p-10 text-center text-sm text-red-600">
          {error}{" "}
          <button onClick={load} className="ml-2 text-slate-900 underline">
            Try again
          </button>
        </Card>
      ) : plans.length === 0 ? (
        <Card className="p-10 text-center text-sm text-slate-500">
          No plans available yet.
        </Card>
      ) : (
        <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
          {plans.map((p) => {
            const isEditing = editing === p.code;
            return (
              <Card
                key={p.code}
                className="relative p-6 transition duration-300 hover:border-blue-500"
              >
                <div className="flex items-center justify-between">
                  <h3 className="text-base font-semibold text-slate-900">
                    {p.name || p.code}
                  </h3>
                  <span className="rounded-full border border-slate-200 bg-slate-50 px-2 py-0.5 font-mono text-[10px] text-slate-500">
                    {p.code}
                  </span>
                </div>

                {isEditing ? (
                  <div className="mt-4 space-y-3">
                    <div>
                      <label className="mb-1 block text-xs text-slate-500">
                        Price / month (USD)
                      </label>
                      <input
                        type="number"
                        min="0"
                        value={form.priceMonthly}
                        onChange={(e) => set("priceMonthly", e.target.value)}
                        className={fieldCls}
                      />
                    </div>
                    <div>
                      <label className="mb-1 block text-xs text-slate-500">
                        Description
                      </label>
                      <textarea
                        rows={2}
                        value={form.description}
                        onChange={(e) => set("description", e.target.value)}
                        className={`${fieldCls} resize-none`}
                      />
                    </div>
                    {LIMIT_FIELDS.map(([key, label]) => (
                      <div key={key}>
                        <label className="mb-1 block text-xs text-slate-500">
                          {label}
                        </label>
                        <input
                          type="number"
                          min="0"
                          value={form[key]}
                          onChange={(e) => set(key, e.target.value)}
                          className={fieldCls}
                        />
                      </div>
                    ))}
                    <label className="flex items-center gap-2 text-sm text-slate-600">
                      <input
                        type="checkbox"
                        checked={!!form.active}
                        onChange={(e) => set("active", e.target.checked)}
                        className="accent-violet-400"
                      />
                      Active — available to customers
                    </label>
                    <div className="flex gap-2 pt-1">
                      <button
                        onClick={() => save(p.code)}
                        disabled={busy}
                        className="flex-1 rounded-lg bg-slate-900 py-2 text-sm font-semibold text-white transition hover:bg-slate-800 disabled:opacity-50"
                      >
                        {busy ? "Saving…" : "Save"}
                      </button>
                      <button
                        onClick={() => setEditing(null)}
                        disabled={busy}
                        className="rounded-lg border border-slate-200 px-3 py-2 text-sm font-semibold text-slate-900 transition hover:bg-slate-100 disabled:opacity-40"
                      >
                        Cancel
                      </button>
                    </div>
                  </div>
                ) : (
                  <>
                    <p className="mt-2 text-2xl font-bold text-slate-900">
                      {money(p.priceMonthly)}
                      <span className="text-sm font-normal text-slate-500">
                        /mo
                      </span>
                    </p>
                    {p.description && (
                      <p className="mt-1 text-xs text-slate-500">
                        {p.description}
                      </p>
                    )}
                    <dl className="mt-4 space-y-2 border-t border-slate-200 pt-4 text-sm">
                      {LIMIT_FIELDS.map(([key, label]) => (
                        <div key={key} className="flex justify-between">
                          <dt className="text-slate-500">{label}</dt>
                          <dd className="text-slate-700">{p[key] ?? "—"}</dd>
                        </div>
                      ))}
                    </dl>
                    <button
                      onClick={() => startEdit(p)}
                      className="mt-5 w-full rounded-lg border border-slate-200 py-2 text-sm font-semibold text-slate-900 transition hover:bg-slate-100"
                    >
                      Edit plan
                    </button>
                  </>
                )}
              </Card>
            );
          })}
        </div>
      )}

      <p className="mt-6 text-xs text-slate-500">
        The plan set is fixed (STARTER, TEAM, BUSINESS, ENTERPRISE). Changes
        apply to the live catalog as soon as they are saved.
      </p>
      <div className="mt-2">
        <SmallButton icon="pulse" onClick={load}>
          Refresh
        </SmallButton>
      </div>
    </div>
  );
}
