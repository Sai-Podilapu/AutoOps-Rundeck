import React, { useCallback, useEffect, useState } from "react";
import {
  PageHeader,
  Card,
  StatCard,
  SmallButton,
  ConfirmModal,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import { tiers } from "../../data/saasData";
import { useStore } from "../../store/store";
import { api } from "../../lib/api";

const PLAN_ORDER = ["STARTER", "TEAM", "BUSINESS", "ENTERPRISE"];
const PLAN_LABELS = {
  STARTER: "Starter",
  TEAM: "Team",
  BUSINESS: "Business",
  ENTERPRISE: "Enterprise",
};
const STATUS_TONE = {
  ACTIVE: "text-emerald-600 border-emerald-400/30 bg-emerald-400/10",
  TRIALING: "text-slate-900 border-slate-300 bg-slate-100",
  PAST_DUE: "text-amber-600 border-amber-400/30 bg-amber-400/10",
  CANCELED: "text-rose-300 border-rose-400/30 bg-rose-400/10",
  INCOMPLETE: "text-slate-600 border-slate-200 bg-slate-50",
};

const fmtLimit = (n) =>
  n === -1 || n === "Unlimited" ? "Unlimited" : (n ?? "—");
const usageLabel = (used, limit) => `${used ?? "—"} / ${fmtLimit(limit)}`;
const fmtDate = (d) =>
  d
    ? new Date(d).toLocaleDateString(undefined, {
        year: "numeric",
        month: "short",
        day: "numeric",
      })
    : "\u2014";

export default function Billing() {
  const { clientRole, pushToast, refreshWorkspace } = useStore();
  const isAdmin = clientRole === "admin";

  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [status, setStatus] = useState(null);
  const [ws, setWs] = useState(null);
  const [usage, setUsage] = useState({
    projects: null,
    nodes: null,
    members: null,
  });
  const [busy, setBusy] = useState(null);
  const [confirm, setConfirm] = useState(null); // { plan } | { cancel: true }

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [s, w] = await Promise.all([
        api.billingStatus(),
        api.getWorkspace(),
      ]);
      setStatus(s);
      setWs(w);
      // Live usage counts. Each is non-fatal: a failed fetch (e.g. members
      // is admin-only) renders as "—" instead of breaking the page.
      const [projects, members] = await Promise.all([
        api.listProjects().catch(() => null),
        api.list("members").catch(() => null),
      ]);
      let nodes = null;
      if (projects) {
        const perProject = await Promise.all(
          projects.map((p) =>
            api
              .list("nodes", p.id)
              .then((rows) => rows.length)
              .catch(() => 0),
          ),
        );
        nodes = perProject.reduce((a, b) => a + b, 0);
      }
      setUsage({
        projects: projects ? projects.length : null,
        nodes,
        members: members ? members.length : null,
      });
    } catch (e) {
      setError(e.message || "Failed to load billing details");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const doSubscribe = async (plan) => {
    setBusy(plan);
    try {
      const s = await api.subscribePlan(plan);
      setStatus(s);
      await refreshWorkspace?.();
      await load();
      pushToast(`Now on the ${PLAN_LABELS[plan]} plan`, "emerald");
    } catch (e) {
      pushToast(e.message || "Could not change plan", "red");
    } finally {
      setBusy(null);
      setConfirm(null);
    }
  };

  const doCancel = async () => {
    setBusy("cancel");
    try {
      const s = await api.cancelSubscription();
      setStatus(s);
      await load();
      pushToast("Subscription set to cancel at period end", "amber");
    } catch (e) {
      pushToast(e.message || "Could not cancel", "red");
    } finally {
      setBusy(null);
      setConfirm(null);
    }
  };

  const currentPlan = status?.plan || ws?.workspace?.plan || null;
  const currentIdx = currentPlan ? PLAN_ORDER.indexOf(currentPlan) : -1;
  const limits = status?.limits || {};
  const sub = status?.subscription || {};
  const subStatus = sub.status || "INCOMPLETE";

  return (
    <div className="space-y-6">
      <PageHeader
        title="Plan & Billing"
        subtitle="Manage your workspace subscription, plan limits, and usage."
      />

      {loading && (
        <Card className="p-6 text-sm text-slate-500">
          Loading billing\u2026
        </Card>
      )}

      {!loading && error && (
        <Card className="p-6">
          <p className="text-sm text-rose-300">{error}</p>
          <div className="mt-3">
            <SmallButton icon="bolt" variant="primary" onClick={load}>
              Retry
            </SmallButton>
          </div>
        </Card>
      )}

      {!loading && !error && (
        <>
          {/* Current subscription summary */}
          <Card className="p-6">
            <div className="flex flex-wrap items-start justify-between gap-4">
              <div>
                <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
                  Current plan
                </p>
                <div className="mt-1 flex items-center gap-3">
                  <h3 className="text-2xl font-bold text-slate-900">
                    {currentPlan ? PLAN_LABELS[currentPlan] : "\u2014"}
                  </h3>
                  <span
                    className={`inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-medium capitalize ${
                      STATUS_TONE[subStatus] || STATUS_TONE.INCOMPLETE
                    }`}
                  >
                    {subStatus.toLowerCase().replace("_", " ")}
                  </span>
                </div>
                <p className="mt-2 text-sm text-slate-500">
                  {sub.cancelAtPeriodEnd
                    ? `Cancels on ${fmtDate(sub.currentPeriodEnd)}`
                    : sub.currentPeriodEnd
                      ? `Renews on ${fmtDate(sub.currentPeriodEnd)}`
                      : "No active billing period yet"}
                </p>
              </div>
              <div className="text-right">
                <p className="text-xs text-slate-500">
                  Payment gateway:{" "}
                  <span className="text-slate-600">
                    {status?.gateway === "stripe"
                      ? "Stripe"
                      : "Internal (built-in)"}
                  </span>
                </p>
                {isAdmin &&
                  currentPlan &&
                  subStatus === "ACTIVE" &&
                  !sub.cancelAtPeriodEnd && (
                    <div className="mt-3">
                      <SmallButton
                        icon="lock"
                        variant="ghost"
                        onClick={() => setConfirm({ cancel: true })}
                      >
                        Cancel subscription
                      </SmallButton>
                    </div>
                  )}
              </div>
            </div>
          </Card>

          {/* Usage vs entitlements */}
          <div className="grid gap-4 sm:grid-cols-3">
            <StatCard
              label="Projects"
              value={usageLabel(usage.projects, limits.projects)}
              icon="folder"
              tone="cyan"
            />
            <StatCard
              label="Nodes"
              value={usageLabel(usage.nodes, limits.nodes)}
              icon="server"
              tone="violet"
            />
            <StatCard
              label="Members"
              value={usage.members ?? "—"}
              icon="users"
              tone="emerald"
            />
          </div>

          {!isAdmin && (
            <Card className="p-4 text-sm text-slate-500">
              You can view the workspace plan and usage. Only a workspace admin
              can change the subscription.
            </Card>
          )}

          {/* Plan catalog */}
          <div className="grid gap-4 lg:grid-cols-4 sm:grid-cols-2">
            {PLAN_ORDER.map((plan, idx) => {
              const label = PLAN_LABELS[plan];
              const t = tiers[label] || {};
              const isCurrent = plan === currentPlan;
              const isDowngrade = currentIdx >= 0 && idx < currentIdx;
              let actionLabel = "Subscribe";
              if (isCurrent) actionLabel = "Current plan";
              else if (currentIdx >= 0 && idx > currentIdx)
                actionLabel = "Upgrade";
              else if (isDowngrade) actionLabel = "Included in your plan";
              return (
                <Card
                  key={plan}
                  className={`flex flex-col p-5 ${
                    isCurrent ? "!border-blue-500 !bg-blue-50" : ""
                  }`}
                >
                  <div className="flex items-center justify-between">
                    <h4 className="text-lg font-semibold text-slate-900">
                      {label}
                    </h4>
                    {isCurrent && (
                      <span className="rounded-full border border-blue-500 bg-blue-100 px-2 py-0.5 text-[10px] font-medium uppercase text-blue-700">
                        Current
                      </span>
                    )}
                  </div>
                  <p className="mt-2">
                    <span className="text-3xl font-bold text-slate-900">
                      ${t.price}
                    </span>
                    <span className="text-sm text-slate-500">/mo</span>
                  </p>
                  <ul className="mt-4 space-y-2 text-sm text-slate-600">
                    <li className="flex items-center gap-2">
                      <Icon name="folder" size={14} /> {fmtLimit(t.projects)}{" "}
                      projects
                    </li>
                    <li className="flex items-center gap-2">
                      <Icon name="server" size={14} /> {fmtLimit(t.nodes)} nodes
                    </li>
                    <li className="flex items-center gap-2">
                      <Icon name="bolt" size={14} /> {fmtLimit(t.automations)}{" "}
                      automations
                    </li>
                    <li className="flex items-center gap-2">
                      <Icon name="play" size={14} /> {fmtLimit(t.jobs)} jobs
                    </li>
                    <li className="flex items-center gap-2">
                      <Icon name="cloud" size={14} /> {fmtLimit(t.integrations)}{" "}
                      cloud integrations
                    </li>
                    <li className="flex items-center gap-2">
                      <Icon name="clock" size={14} /> {t.history} history
                    </li>
                    <li className="flex items-center gap-2">
                      <Icon name="shield" size={14} /> {t.rbac} RBAC
                    </li>
                    <li className="flex items-center gap-2 text-slate-500">
                      <Icon name={t.sso ? "check" : "lock"} size={14} />{" "}
                      {t.sso ? "SSO included" : "No SSO"}
                    </li>
                  </ul>
                  <div className="mt-5 pt-1">
                    <SmallButton
                      icon={isCurrent ? "check" : isDowngrade ? "lock" : "bolt"}
                      variant={isCurrent || isDowngrade ? "ghost" : "primary"}
                      disabled={
                        !isAdmin || isCurrent || isDowngrade || busy === plan
                      }
                      onClick={() => setConfirm({ plan })}
                    >
                      {busy === plan ? "Working\u2026" : actionLabel}
                    </SmallButton>
                  </div>
                </Card>
              );
            })}
          </div>
        </>
      )}

      <ConfirmModal
        open={!!confirm}
        title={
          confirm?.cancel
            ? "Cancel subscription?"
            : `Switch to ${confirm ? PLAN_LABELS[confirm.plan] : ""} plan?`
        }
        message={
          confirm?.cancel
            ? "Your workspace will keep its current plan until the end of the billing period, then downgrade."
            : "Your workspace plan and limits will update immediately."
        }
        confirmLabel={confirm?.cancel ? "Cancel plan" : "Confirm"}
        cancelLabel="Keep current"
        tone={confirm?.cancel ? "danger" : "primary"}
        onConfirm={() =>
          confirm?.cancel ? doCancel() : doSubscribe(confirm.plan)
        }
        onClose={() => setConfirm(null)}
      />
    </div>
  );
}
