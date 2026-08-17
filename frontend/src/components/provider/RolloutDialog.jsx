import React, { useEffect, useState } from "react";
import Icon from "../Icon";
import { api } from "../../lib/api";
import ModalPortal from "../app/ModalPortal";

/**
 * Deliver one catalog workflow or agent to chosen customers.
 *
 * A rollout is per (tenant, project) because a workflow has to land somewhere
 * concrete — so picking a customer is only half the answer, and this asks for
 * the other half rather than guessing at their first project.
 *
 * Projects are fetched lazily, per customer, when that customer is ticked:
 * eagerly loading every tenant's projects would be N requests to answer a
 * question about the two the provider actually selected.
 *
 * A rollout can PARTLY succeed (one customer's plan is expired, another has a
 * name clash), so the result is reported per customer instead of collapsing to
 * "done" or "failed".
 */
export default function RolloutDialog({ item, onClose, onDone }) {
  const [tenants, setTenants] = useState(null);
  const [projects, setProjects] = useState({}); // tenantId -> [] | "loading" | "error"
  const [chosen, setChosen] = useState({}); // tenantId -> projectId
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    let alive = true;
    api
      .providerTenantsMerged()
      .then((rows) => alive && setTenants(Array.isArray(rows) ? rows : []))
      .catch((e) => alive && setError(e.message || "Could not load customers"));
    return () => {
      alive = false;
    };
  }, []);

  const loadProjects = async (tenantId) => {
    setProjects((p) => ({ ...p, [tenantId]: "loading" }));
    try {
      const rows = await api.providerTenantProjects(tenantId);
      const active = (rows || []).filter((r) => r.status === "ACTIVE");
      setProjects((p) => ({ ...p, [tenantId]: active }));
      // One project is not a choice — pick it so the provider does not have to.
      if (active.length === 1) {
        setChosen((c) => ({ ...c, [tenantId]: active[0].id }));
      }
    } catch {
      setProjects((p) => ({ ...p, [tenantId]: "error" }));
    }
  };

  const toggleTenant = (tenantId) => {
    const wasSelected = tenantId in chosen;
    setChosen((c) => {
      const next = { ...c };
      if (wasSelected) delete next[tenantId];
      else next[tenantId] = null;
      return next;
    });
    if (!wasSelected && projects[tenantId] === undefined) loadProjects(tenantId);
  };

  // Only customers with a project actually chosen are deliverable.
  const targets = Object.entries(chosen)
    .filter(([, projectId]) => projectId != null)
    .map(([tenantId, projectId]) => ({ tenantId, projectId }));

  const submit = async () => {
    setBusy(true);
    setError(null);
    try {
      const res = await api.providerRollOut(item.id, targets);
      setResult(res);
      if (res.delivered > 0) onDone?.();
    } catch (e) {
      setError(e.message || "Rollout failed");
    } finally {
      setBusy(false);
    }
  };

  const tenantName = (id) =>
    tenants?.find((t) => t.tenantId === id)?.name || id;

  return (
    <ModalPortal layerClass="z-50 items-center p-4" onClose={onClose}>
      <div className="animate-fade-up relative flex max-h-[85vh] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-xl">
        <div className="flex items-start justify-between border-b border-slate-200 px-6 py-4">
          <div>
            <h2 className="text-base font-semibold text-slate-900">
              Roll out “{item.title}”
            </h2>
            <p className="mt-0.5 text-xs text-slate-500">
              Customers can run it, pause it and see its history — never its{" "}
              {item.type === "agent" ? "instructions" : "design"}.
            </p>
          </div>
          <button
            onClick={onClose}
            aria-label="Close"
            className="text-slate-400 transition hover:text-slate-700"
          >
            <Icon name="x" size={18} />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto px-6 py-4">
          {result ? (
            <div className="space-y-3">
              <p className="text-sm text-slate-700">
                Delivered to <strong>{result.delivered}</strong> of{" "}
                {result.deliveries.length} customer
                {result.deliveries.length === 1 ? "" : "s"}.
              </p>
              <div className="space-y-1.5">
                {result.deliveries.map((d) => (
                  <div
                    key={d.tenantId}
                    className={`flex items-start gap-2 rounded-lg border px-3 py-2 text-xs ${
                      d.error
                        ? "border-red-400/30 bg-red-400/5 text-red-700"
                        : "border-emerald-400/30 bg-emerald-400/5 text-emerald-700"
                    }`}
                  >
                    <Icon name={d.error ? "warning" : "check"} size={14} />
                    <span className="min-w-0">
                      <strong className="text-slate-900">
                        {tenantName(d.tenantId)}
                      </strong>
                      {d.error ? ` — ${d.error}` : " — delivered"}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          ) : error ? (
            <p className="text-sm text-red-600">{error}</p>
          ) : tenants === null ? (
            <p className="text-sm text-slate-500">Loading customers…</p>
          ) : tenants.length === 0 ? (
            <p className="text-sm text-slate-500">No customers yet.</p>
          ) : (
            <div className="space-y-2">
              {tenants.map((t) => {
                const selected = t.tenantId in chosen;
                const list = projects[t.tenantId];
                return (
                  <div
                    key={t.tenantId}
                    className={`rounded-xl border px-3 py-2.5 transition ${
                      selected
                        ? "border-violet-400/40 bg-violet-400/[0.04]"
                        : "border-slate-200"
                    }`}
                  >
                    <label className="flex cursor-pointer items-center gap-2.5">
                      <input
                        type="checkbox"
                        checked={selected}
                        onChange={() => toggleTenant(t.tenantId)}
                        className="h-4 w-4 rounded border-slate-300 accent-violet-600"
                      />
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-medium text-slate-900">
                          {t.name}
                        </span>
                        <span className="block truncate font-mono text-[10px] text-slate-400">
                          {t.tenantId}
                        </span>
                      </span>
                    </label>

                    {selected && (
                      <div className="mt-2 pl-7">
                        {list === "loading" ? (
                          <p className="text-xs text-slate-500">Loading projects…</p>
                        ) : list === "error" ? (
                          <button
                            onClick={() => loadProjects(t.tenantId)}
                            className="text-xs text-red-600 underline"
                          >
                            Could not load projects — retry
                          </button>
                        ) : (list || []).length === 0 ? (
                          <p className="text-xs text-amber-600">
                            No active project to deliver into.
                          </p>
                        ) : (
                          <select
                            value={chosen[t.tenantId] ?? ""}
                            onChange={(e) =>
                              setChosen((c) => ({
                                ...c,
                                [t.tenantId]: Number(e.target.value) || null,
                              }))
                            }
                            className="w-full rounded-lg border border-slate-200 bg-slate-50 px-2.5 py-1.5 text-xs text-slate-700 outline-none focus:border-violet-400"
                          >
                            <option value="">Choose a project…</option>
                            {list.map((p) => (
                              <option key={p.id} value={p.id}>
                                {p.name}
                              </option>
                            ))}
                          </select>
                        )}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>

        <div className="flex items-center justify-between gap-3 border-t border-slate-200 px-6 py-3">
          <span className="text-xs text-slate-500">
            {result
              ? ""
              : `${targets.length} customer${targets.length === 1 ? "" : "s"} selected`}
          </span>
          <div className="flex gap-2">
            <button
              onClick={onClose}
              className="rounded-lg border border-slate-200 bg-slate-50 px-3.5 py-1.5 text-sm text-slate-700 transition hover:border-slate-300"
            >
              {result ? "Close" : "Cancel"}
            </button>
            {!result && (
              <button
                onClick={submit}
                disabled={busy || targets.length === 0}
                className="rounded-lg bg-slate-900 px-4 py-1.5 text-sm font-semibold text-white transition hover:bg-slate-800 disabled:opacity-40"
              >
                {busy ? "Rolling out…" : "Roll out"}
              </button>
            )}
          </div>
        </div>
      </div>
    </ModalPortal>
  );
}
