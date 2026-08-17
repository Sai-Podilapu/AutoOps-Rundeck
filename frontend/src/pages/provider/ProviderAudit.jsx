import React, { useMemo, useState, useEffect } from "react";
import {
  PageHeader,
  Toolbar,
  Table,
  Chip,
  Pagination,
} from "../../components/app/appui";
import { api } from "../../lib/api";

const when = (d) => {
  if (!d) return "—";
  try {
    return new Date(d).toLocaleString();
  } catch {
    return "—";
  }
};

const EVENT_TONE = {
  SUBSCRIBED: "text-emerald-600",
  PLAN_CHANGED: "text-violet-600",
  PLAN_UPDATED: "text-violet-600",
  CANCELED: "text-amber-600",
  PAYMENT_SUCCEEDED: "text-emerald-600",
  PAYMENT_FAILED: "text-red-600",
};

export default function ProviderAudit() {
  const [tenant, setTenant] = useState("all");
  const [search, setSearch] = useState("");
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [page, setPage] = useState(1);
  const pageSize = 10;

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await api.providerAudit();
      setItems(Array.isArray(data) ? data : []);
    } catch (e) {
      setError(e.message || "Could not load audit log");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
  }, []);

  const tenantOptions = useMemo(
    () =>
      Array.from(new Set(items.map((r) => r.tenantId).filter(Boolean))).sort(),
    [items],
  );

  const filtered = useMemo(() => {
    let res =
      tenant === "all" ? items : items.filter((r) => r.tenantId === tenant);
    if (search.trim()) {
      const q = search.toLowerCase();
      res = res.filter((r) =>
        [r.eventType, r.actor, r.detail, r.tenantId, r.planCode]
          .filter(Boolean)
          .some((v) => String(v).toLowerCase().includes(q)),
      );
    }
    return [...res].sort(
      (a, b) => new Date(b.createdAt || 0) - new Date(a.createdAt || 0),
    );
  }, [tenant, search, items]);

  const totalPages = Math.ceil(filtered.length / pageSize) || 1;
  const currentPage = Math.min(page, totalPages);
  const rows = filtered.slice(
    (currentPage - 1) * pageSize,
    currentPage * pageSize,
  );

  const handleSearchChange = (e) => {
    setSearch(e.target.value);
    setPage(1);
  };

  const handleTenantChange = (e) => {
    setTenant(e.target.value);
    setPage(1);
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Provider Audit Log"
        subtitle="Billing events across all tenants: subscriptions, plan changes, payments"
      />
      <Toolbar
        placeholder="Search events…"
        value={search}
        onChange={handleSearchChange}
        right={
          <div className="flex items-center gap-2">
            <select
              value={tenant}
              onChange={handleTenantChange}
              className="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-900 outline-none transition focus:border-violet-400/50"
            >
              <option value="all">All tenants</option>
              {tenantOptions.map((t) => (
                <option key={t} value={t}>
                  {t}
                </option>
              ))}
            </select>
            <Chip>immutable</Chip>
          </div>
        }
      />
      <p className="mb-3 text-xs text-slate-500">
        Showing {filtered.length} event{filtered.length === 1 ? "" : "s"}
        {tenant === "all" ? " across all tenants" : ` for ${tenant}`}.
      </p>
      <Table
        loading={loading}
        error={error}
        onRetry={load}
        columns={[
          {
            key: "createdAt",
            label: "Time",
            render: (r) => (
              <span className="font-mono text-xs text-slate-500">
                {when(r.createdAt)}
              </span>
            ),
          },
          {
            key: "eventType",
            label: "Event",
            render: (r) => (
              <span
                className={`font-mono text-xs ${EVENT_TONE[String(r.eventType || "").toUpperCase()] || "text-violet-600"}`}
              >
                {r.eventType}
              </span>
            ),
          },
          {
            key: "tenantId",
            label: "Tenant",
            render: (r) => (
              <span className="font-mono text-xs text-slate-600">
                {r.tenantId || "—"}
              </span>
            ),
          },
          {
            key: "planCode",
            label: "Plan",
            render: (r) =>
              r.planCode ? (
                <Chip>{r.planCode}</Chip>
              ) : (
                <span className="text-slate-400">—</span>
              ),
          },
          {
            key: "actor",
            label: "Actor",
            render: (r) => (
              <span className="font-medium text-slate-900">
                {r.actor || "—"}
              </span>
            ),
          },
          {
            key: "detail",
            label: "Detail",
            render: (r) => <span className="text-slate-500">{r.detail}</span>,
          },
        ]}
        rows={rows}
        empty="No audit events yet."
      />
      <Pagination
        page={currentPage}
        pageSize={pageSize}
        totalItems={filtered.length}
        onPageChange={setPage}
      />
    </div>
  );
}
