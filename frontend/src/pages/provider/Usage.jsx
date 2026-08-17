import React, { useState, useEffect, useMemo } from "react";
import { Link } from "react-router-dom";
import {
  PageHeader,
  Card,
  Table,
  StatCard,
  Toolbar,
  Pagination,
} from "../../components/app/appui";
import { api } from "../../lib/api";

const failureRate = (r) => {
  const runs = Number(r.runs30d || 0);
  const failed = Number(r.failedRuns30d || 0);
  if (!runs) return null;
  return (failed / runs) * 100;
};

export default function Usage() {
  const [query, setQuery] = useState("");
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const [page, setPage] = useState(1);
  const pageSize = 10;

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await api.providerUsage();
      setItems(Array.isArray(data) ? data : []);
    } catch (e) {
      setError(e.message || "Could not load usage");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
  }, []);

  const totals = useMemo(
    () =>
      items.reduce(
        (acc, r) => ({
          projects: acc.projects + Number(r.projects || 0),
          runs30d: acc.runs30d + Number(r.runs30d || 0),
          failed30d: acc.failed30d + Number(r.failedRuns30d || 0),
        }),
        { projects: 0, runs30d: 0, failed30d: 0 },
      ),
    [items],
  );
  const overallRate = totals.runs30d
    ? ((totals.failed30d / totals.runs30d) * 100).toFixed(1) + "%"
    : "—";

  const filtered = items.filter((t) =>
    String(t.tenantId || "").toLowerCase().includes(query.toLowerCase()),
  );

  const totalPages = Math.ceil(filtered.length / pageSize) || 1;
  const currentPage = Math.min(page, totalPages);
  const visibleList = filtered.slice(
    (currentPage - 1) * pageSize,
    currentPage * pageSize,
  );

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Usage & Quotas"
        subtitle="Monitor tenant resource consumption across the platform"
      />
      <div className="grid gap-4 sm:grid-cols-3">
        <StatCard
          label="Total projects"
          value={totals.projects.toLocaleString()}
          icon="server"
          tone="violet"
        />
        <StatCard
          label="Runs (last 30 days)"
          value={totals.runs30d.toLocaleString()}
          icon="play"
          tone="cyan"
        />
        <StatCard
          label="Failure rate (30d)"
          value={overallRate}
          icon="alert"
          tone={totals.failed30d ? "amber" : "emerald"}
        />
      </div>
      <Card className="mt-6 p-1">
        <div className="p-4">
          <Toolbar
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setPage(1);
            }}
            placeholder="Search by tenant id..."
          />
        </div>
        <Table
          loading={loading}
          error={error}
          onRetry={load}
          empty="No usage data yet."
          columns={[
            {
              key: "tenantId",
              label: "Tenant",
              render: (r) => (
                <Link
                  to={`/provider/tenants/${r.tenantId}`}
                  className="font-mono text-xs font-medium text-slate-900 hover:text-violet-600"
                >
                  {r.tenantId}
                </Link>
              ),
            },
            {
              key: "projects",
              label: "Projects",
              render: (r) => (
                <span className="text-slate-600">
                  {Number(r.projects || 0).toLocaleString()}
                </span>
              ),
            },
            {
              key: "workflows",
              label: "Workflows",
              render: (r) => (
                <span className="text-slate-600">
                  {Number(r.workflows || 0).toLocaleString()}
                </span>
              ),
            },
            {
              key: "jobs",
              label: "Jobs",
              render: (r) => (
                <span className="text-slate-600">
                  {Number(r.jobs || 0).toLocaleString()}
                </span>
              ),
            },
            {
              key: "runs30d",
              label: "Runs (30d)",
              render: (r) => (
                <span className="text-slate-600">
                  {Number(r.runs30d || 0).toLocaleString()}
                </span>
              ),
            },
            {
              key: "failedRuns30d",
              label: "Failed (30d)",
              render: (r) => (
                <span
                  className={
                    Number(r.failedRuns30d || 0) > 0
                      ? "text-red-600"
                      : "text-slate-500"
                  }
                >
                  {Number(r.failedRuns30d || 0).toLocaleString()}
                </span>
              ),
            },
            {
              key: "rate",
              label: "Failure rate",
              render: (r) => {
                const rate = failureRate(r);
                if (rate == null)
                  return <span className="text-slate-400">—</span>;
                return (
                  <span
                    className={`text-sm font-medium ${rate > 20 ? "text-red-600" : rate > 5 ? "text-amber-600" : "text-emerald-600"}`}
                  >
                    {rate.toFixed(1)}%
                  </span>
                );
              },
            },
          ]}
          rows={visibleList}
        />
        <div className="px-5 pb-5">
          <Pagination
            page={currentPage}
            pageSize={pageSize}
            totalItems={filtered.length}
            onPageChange={setPage}
          />
        </div>
      </Card>
    </div>
  );
}
