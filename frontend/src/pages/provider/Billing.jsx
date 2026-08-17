import React, { useState, useMemo, useEffect } from "react";
import { Link } from "react-router-dom";
import {
  PageHeader,
  StatCard,
  Card,
  Toolbar,
  Table,
  StatusBadge,
  Pagination,
} from "../../components/app/appui";
import { api } from "../../lib/api";

const when = (d) => {
  if (!d) return "—";
  try {
    return new Date(d).toLocaleDateString();
  } catch {
    return "—";
  }
};

export default function Billing() {
  const [search, setSearch] = useState("");
  const [items, setItems] = useState([]);
  const [tenants, setTenants] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [page, setPage] = useState(1);
  const pageSize = 10;

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const [inv, t] = await Promise.all([
        api.providerInvoices(),
        api.providerTenantsMerged(),
      ]);
      setItems(Array.isArray(inv) ? inv : []);
      setTenants(Array.isArray(t) ? t : []);
    } catch (e) {
      setError(e.message || "Could not load billing data");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const activeSubs = tenants
    .map((t) => t.subscription)
    .filter((s) => s && s.status === "ACTIVE");
  const mrr = activeSubs.reduce(
    (sum, s) => sum + Number(s.priceMonthly || 0),
    0,
  );
  const collected =
    items
      .filter((i) => String(i.status || "").toUpperCase() === "SUCCEEDED")
      .reduce((sum, i) => sum + Number(i.amountCents || 0), 0) / 100;
  const failedCount = items.filter(
    (i) => String(i.status || "").toUpperCase() === "FAILED",
  ).length;

  const revenueByPlan = useMemo(() => {
    const map = {};
    activeSubs.forEach((s) => {
      const key = s.planName || s.planCode || "Unknown";
      map[key] = (map[key] || 0) + Number(s.priceMonthly || 0);
    });
    return Object.entries(map).sort((a, b) => b[1] - a[1]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tenants]);
  const maxPlanRevenue = Math.max(1, ...revenueByPlan.map(([, v]) => v));

  const filtered = useMemo(() => {
    if (!search.trim()) return items;
    const q = search.toLowerCase();
    return items.filter(
      (i) =>
        String(i.id || "").toLowerCase().includes(q) ||
        String(i.tenantId || "").toLowerCase().includes(q) ||
        String(i.planCode || "").toLowerCase().includes(q),
    );
  }, [search, items]);

  const sorted = useMemo(
    () =>
      [...filtered].sort(
        (a, b) => new Date(b.createdAt || 0) - new Date(a.createdAt || 0),
      ),
    [filtered],
  );

  const totalPages = Math.ceil(sorted.length / pageSize) || 1;
  const currentPage = Math.min(page, totalPages);
  const rows = sorted.slice(
    (currentPage - 1) * pageSize,
    currentPage * pageSize,
  );

  const handleSearchChange = (e) => {
    setSearch(e.target.value);
    setPage(1);
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Billing"
        subtitle="Revenue and payment history across tenants"
      />
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard
          label="MRR"
          value={`$${mrr.toLocaleString()}`}
          icon="chart"
          tone="emerald"
        />
        <StatCard
          label="Active subscriptions"
          value={activeSubs.length.toLocaleString()}
          icon="users"
          tone="violet"
        />
        <StatCard
          label="Payments collected"
          value={`$${collected.toLocaleString()}`}
          icon="chart"
          tone="cyan"
        />
        <StatCard
          label="Failed payments"
          value={failedCount.toLocaleString()}
          icon="bolt"
          tone={failedCount ? "amber" : "emerald"}
        />
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <Card className="p-6">
          <h3 className="mb-4 text-sm font-semibold text-slate-900">
            Revenue by plan (MRR)
          </h3>
          {revenueByPlan.length === 0 ? (
            <p className="text-sm text-slate-500">
              {loading ? "Loading…" : "No active subscriptions yet."}
            </p>
          ) : (
            <div className="space-y-3">
              {revenueByPlan.map(([plan, amount]) => (
                <div key={plan}>
                  <div className="mb-1 flex items-center justify-between text-sm">
                    <span className="text-slate-600">{plan}</span>
                    <span className="text-emerald-600">
                      ${amount.toLocaleString()}/mo
                    </span>
                  </div>
                  <div className="h-1.5 overflow-hidden rounded-full bg-slate-50">
                    <div
                      className="h-full rounded-full bg-gradient-to-r from-slate-900 to-slate-900"
                      style={{ width: `${(amount / maxPlanRevenue) * 100}%` }}
                    />
                  </div>
                </div>
              ))}
            </div>
          )}
        </Card>

        <div className="lg:col-span-2">
          <Toolbar
            placeholder="Search payments…"
            value={search}
            onChange={handleSearchChange}
          />
          <Table
            loading={loading}
            error={error}
            onRetry={load}
            empty="No payments yet."
            columns={[
              {
                key: "id",
                label: "Payment",
                render: (r) => (
                  <span className="font-mono text-xs text-slate-600">
                    {r.id}
                  </span>
                ),
              },
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
                    ${(Number(r.amountCents || 0) / 100).toLocaleString()}{" "}
                    {r.currency || ""}
                  </span>
                ),
              },
              {
                key: "createdAt",
                label: "Date",
                render: (r) => (
                  <span className="text-slate-500">{when(r.createdAt)}</span>
                ),
              },
              {
                key: "status",
                label: "Status",
                render: (r) => (
                  <div>
                    <StatusBadge
                      status={
                        String(r.status || "").toUpperCase() === "SUCCEEDED"
                          ? "success"
                          : String(r.status || "").toUpperCase() === "FAILED"
                            ? "failed"
                            : String(r.status || "").toLowerCase()
                      }
                    />
                    {r.failureReason && (
                      <p className="mt-1 text-xs text-red-600">
                        {r.failureReason}
                      </p>
                    )}
                  </div>
                ),
              },
            ]}
            rows={rows}
          />
          <Pagination
            page={currentPage}
            pageSize={pageSize}
            totalItems={sorted.length}
            onPageChange={setPage}
          />
        </div>
      </div>
    </div>
  );
}
