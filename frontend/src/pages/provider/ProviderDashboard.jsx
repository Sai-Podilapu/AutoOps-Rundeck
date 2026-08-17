import React, { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import {
  PageHeader,
  StatCard,
  Card,
  Table,
  StatusBadge,
  SmallButton,
} from "../../components/app/appui";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";

const money = (n) => `$${Number(n || 0).toLocaleString()}`;
const when = (d) => {
  if (!d) return "—";
  try {
    return new Date(d).toLocaleDateString();
  } catch {
    return "—";
  }
};

export default function ProviderDashboard() {
  const { pushToast } = useStore();
  const [tenants, setTenants] = useState([]);
  const [usage, setUsage] = useState([]);
  const [payments, setPayments] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const [t, u, p] = await Promise.all([
        api.providerTenantsMerged(),
        api.providerUsage(),
        api.providerInvoices(),
      ]);
      setTenants(Array.isArray(t) ? t : []);
      setUsage(Array.isArray(u) ? u : []);
      setPayments(Array.isArray(p) ? p : []);
    } catch (err) {
      setError(err.message || "Could not load dashboard");
      pushToast(err.message || "Could not load dashboard", "red");
    } finally {
      setLoading(false);
    }
  };
  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const subs = tenants.map((t) => t.subscription).filter(Boolean);
  const activeSubs = subs.filter(
    (s) => s.status === "ACTIVE" || s.status === "TRIALING",
  ).length;
  const mrr = subs
    .filter((s) => s.status === "ACTIVE")
    .reduce((sum, s) => sum + Number(s.priceMonthly || 0), 0);
  const runs30d = usage.reduce((sum, u) => sum + Number(u.runs30d || 0), 0);

  const byPlan = {};
  subs.forEach((s) => {
    const key = s.planName || s.planCode || "Unknown";
    byPlan[key] = (byPlan[key] || 0) + 1;
  });
  const planRows = Object.entries(byPlan).sort((a, b) => b[1] - a[1]);
  const maxCount = Math.max(1, ...planRows.map(([, c]) => c));

  const recentPayments = [...payments]
    .sort((a, b) => new Date(b.createdAt || 0) - new Date(a.createdAt || 0))
    .slice(0, 6);

  const kpis = [
    {
      label: "Tenants",
      value: tenants.length.toLocaleString(),
      icon: "users",
      tone: "violet",
    },
    {
      label: "Active subscriptions",
      value: activeSubs.toLocaleString(),
      icon: "bolt",
      tone: "cyan",
    },
    { label: "MRR", value: money(mrr), icon: "chart", tone: "emerald" },
    {
      label: "Runs (30d)",
      value: runs30d.toLocaleString(),
      icon: "gauge",
      tone: "amber",
    },
  ];

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Provider Dashboard"
        subtitle="Your business across every customer"
        actions={
          <>
            <SmallButton icon="pulse" onClick={load}>
              Refresh
            </SmallButton>
            <Link to="/provider/tenants">
              <SmallButton icon="users" variant="primary">
                Tenants
              </SmallButton>
            </Link>
          </>
        }
      />

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {kpis.map((k) => (
          <StatCard key={k.label} {...k} />
        ))}
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <div className="lg:col-span-2">
          <div className="mb-3 flex items-center justify-between">
            <h3 className="text-sm font-semibold text-slate-900">
              Recent payments
            </h3>
            <Link
              to="/provider/billing"
              className="text-xs font-medium text-violet-600 hover:underline"
            >
              View all →
            </Link>
          </div>
          <Table
            loading={loading}
            error={error}
            onRetry={load}
            empty="No payments yet."
            columns={[
              {
                key: "tenantId",
                label: "Tenant",
                render: (r) => (
                  <Link
                    to={`/provider/tenants/${r.tenantId}`}
                    className="font-mono text-xs text-slate-900 hover:text-violet-600"
                  >
                    {r.tenantId}
                  </Link>
                ),
              },
              { key: "planCode", label: "Plan" },
              {
                key: "amountCents",
                label: "Amount",
                render: (r) => (
                  <span className="text-emerald-600">
                    ${(Number(r.amountCents || 0) / 100).toLocaleString()}
                  </span>
                ),
              },
              {
                key: "status",
                label: "Status",
                render: (r) => (
                  <StatusBadge
                    status={
                      String(r.status || "").toUpperCase() === "SUCCEEDED"
                        ? "success"
                        : String(r.status || "").toUpperCase() === "FAILED"
                          ? "failed"
                          : String(r.status || "").toLowerCase()
                    }
                  />
                ),
              },
              {
                key: "createdAt",
                label: "Date",
                render: (r) => (
                  <span className="text-slate-500">{when(r.createdAt)}</span>
                ),
              },
            ]}
            rows={recentPayments}
          />
        </div>

        <Card className="p-6">
          <h3 className="mb-4 text-sm font-semibold text-slate-900">
            Tenants by plan
          </h3>
          {planRows.length === 0 ? (
            <p className="text-sm text-slate-500">
              {loading ? "Loading…" : "No subscriptions yet."}
            </p>
          ) : (
            <div className="space-y-3">
              {planRows.map(([plan, count]) => (
                <div key={plan}>
                  <div className="mb-1 flex items-center justify-between text-sm">
                    <span className="text-slate-600">{plan}</span>
                    <span className="text-slate-500">{count}</span>
                  </div>
                  <div className="h-1.5 overflow-hidden rounded-full bg-slate-50">
                    <div
                      className="h-full rounded-full bg-gradient-to-r from-slate-900 to-slate-900"
                      style={{ width: `${(count / maxCount) * 100}%` }}
                    />
                  </div>
                </div>
              ))}
            </div>
          )}
          <Link
            to="/provider/plans"
            className="mt-4 inline-block text-xs font-medium text-violet-600 hover:underline"
          >
            Manage plans →
          </Link>
        </Card>
      </div>
    </div>
  );
}
