import React, { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { PageHeader, Card, StatCard } from "../../components/app/appui";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";
import { planAllows, requiredPlan } from "../../lib/entitlements";
import UpgradeNotice from "../../components/app/UpgradeNotice";

const MODE_STYLES = {
  ENFORCED: "border-emerald-400/30 bg-emerald-400/10 text-emerald-600",
  MONITOR: "border-amber-400/30 bg-amber-400/10 text-amber-600",
  DISABLED: "border-slate-200 bg-slate-50 text-slate-500",
};

const MODE_LABELS = { ENFORCED: "Enforced", MONITOR: "Monitor", DISABLED: "Disabled" };

export default function Governance() {
  const { pid } = useParams();
  const { workspace, can, pushToast } = useStore();
  const plan = workspace?.plan;
  const allowed = planAllows(plan, "governance");
  const canManage = can("manageGovernance");
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  const load = () =>
    api
      .getGovernanceSummary()
      .then(setData)
      .catch(() => pushToast("Could not load governance data", "red"));

  useEffect(() => {
    if (!allowed) return;
    let live = true;
    api
      .getGovernanceSummary()
      .then((d) => live && setData(d))
      .catch(() => live && pushToast("Could not load governance data", "red"))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [allowed]); // eslint-disable-line react-hooks/exhaustive-deps

  const setMode = async (policy, mode) => {
    try {
      await api.updateGovernancePolicy(policy.code, mode);
      pushToast(`${policy.name} → ${MODE_LABELS[mode] || mode}`, "emerald");
      await load();
    } catch (e) {
      pushToast(e.message || "Could not update the policy", "red");
    }
  };

  if (!allowed)
    return (
      <div className="animate-fade-up">
        <PageHeader
          title="Governance"
          subtitle="Policies, automation and compliance posture"
        />
        <UpgradeNotice
          feature="Governance automation"
          plan={requiredPlan("governance")}
        />
      </div>
    );

  const s = data || {
    complianceScore: null,
    policiesEnforced: 0,
    openViolations: 0,
    quotaUsage: null,
    automations: [],
    policies: [],
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Governance"
        subtitle="Policy enforcement and governance automation — live from your workspace data"
      />
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard
          label="Compliance score"
          value={s.complianceScore == null ? "—" : s.complianceScore + "%"}
          icon="shield"
          tone="emerald"
          // The score is the average of the newest compliance report per active
          // project, so with no reports there is genuinely nothing to average.
          // A bare dash reads as a broken calculation — say why it is empty.
          hint={
            s.complianceScore == null ? (
              <>
                No compliance reports yet.{" "}
                <Link
                  to={`/app/projects/${pid}/compliance`}
                  className="font-semibold text-blue-600 transition hover:text-blue-700"
                >
                  Generate one
                </Link>{" "}
                to start scoring.
              </>
            ) : null
          }
        />
        <StatCard
          label="Policies enforced"
          value={String(s.policiesEnforced)}
          icon="scale"
          tone="cyan"
        />
        <StatCard
          label="Open violations"
          value={String(s.openViolations)}
          icon="bolt"
          tone="amber"
        />
        <StatCard
          label="Quota usage"
          value={s.quotaUsage == null ? "—" : s.quotaUsage + "%"}
          icon="gauge"
          tone="violet"
        />
      </div>

      <h3 className="mb-3 mt-8 text-sm font-semibold text-slate-900">
        Governance Automation
      </h3>
      <div className="grid gap-4 sm:grid-cols-2">
        {s.automations.map((a) => (
          <Card key={a.name} className="p-5">
            <div className="flex items-start justify-between">
              <p className="text-sm font-semibold text-slate-900">{a.name}</p>
              <span
                className={`rounded-full border px-2.5 py-0.5 text-xs font-medium ${a.enabled ? "border-emerald-400/30 bg-emerald-400/10 text-emerald-600" : "border-slate-200 bg-slate-50 text-slate-500"}`}
              >
                {a.enabled ? "Enabled" : "Off"}
              </span>
            </div>
            <dl className="mt-3 space-y-1.5 text-xs">
              <div className="flex justify-between gap-4">
                <dt className="shrink-0 text-slate-500">Scope</dt>
                <dd className="text-right text-slate-700">{a.scope}</dd>
              </div>
              <div className="flex justify-between gap-4">
                <dt className="shrink-0 text-slate-500">Trigger</dt>
                <dd className="text-right text-slate-700">{a.trigger}</dd>
              </div>
              <div className="flex justify-between gap-4">
                <dt className="shrink-0 text-slate-500">Action</dt>
                <dd className="text-right text-slate-700">{a.action}</dd>
              </div>
            </dl>
          </Card>
        ))}
      </div>

      <Card className="mt-8 overflow-hidden">
        <div className="border-b border-slate-200 px-5 py-3 text-sm font-semibold text-slate-900">
          Policy Enforcement
          {loading && (
            <span className="ml-2 text-xs font-normal text-slate-400">loading…</span>
          )}
        </div>
        <div className="divide-y divide-slate-200">
          {s.policies.map((p) => (
            <div key={p.code} className="px-5 py-3.5 transition hover:bg-slate-100">
              <div className="flex items-center justify-between gap-4">
                <div>
                  <p className="text-sm font-medium text-slate-700">{p.name}</p>
                  <p className="text-xs text-slate-500">
                    {p.scope}
                    {!p.configurable &&
                      (p.code === "RISKY_APPROVAL"
                        ? " · managed in approval settings"
                        : " · enforced by the platform")}
                  </p>
                </div>
                <div className="flex shrink-0 items-center gap-2">
                  {p.violations.length > 0 && (
                    <span className="rounded-full border border-red-400/30 bg-red-400/10 px-2.5 py-0.5 text-xs font-medium text-red-600">
                      {p.violations.length} violation{p.violations.length > 1 ? "s" : ""}
                    </span>
                  )}
                  {canManage && p.configurable ? (
                    <select
                      value={p.mode}
                      onChange={(e) => setMode(p, e.target.value)}
                      className="rounded-lg border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 outline-none transition focus:border-slate-300"
                    >
                      {p.supportsEnforced && <option value="ENFORCED">Enforced</option>}
                      <option value="MONITOR">Monitor</option>
                      <option value="DISABLED">Disabled</option>
                    </select>
                  ) : (
                    <span
                      className={`rounded-full border px-2.5 py-0.5 text-xs font-medium ${MODE_STYLES[p.mode] || MODE_STYLES.DISABLED}`}
                    >
                      {MODE_LABELS[p.mode] || p.mode}
                    </span>
                  )}
                </div>
              </div>
              {p.violations.length > 0 && (
                <ul className="mt-2 space-y-1">
                  {p.violations.map((v, i) => (
                    <li key={i} className="text-xs text-slate-500">
                      <span className="font-medium text-slate-700">{v.subject}</span>
                      {" — "}
                      {v.detail}
                    </li>
                  ))}
                </ul>
              )}
            </div>
          ))}
        </div>
      </Card>
    </div>
  );
}