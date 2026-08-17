import React, { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import {
  PageHeader,
  Toolbar,
  Table,
  StatusBadge,
  SmallButton,
  Chip,
} from "../../components/app/appui";
import { api } from "../../lib/api";
import { downloadCsv } from "../../lib/csv";
import { useStore } from "../../store/store";

const FILTERS = ["All", "Active", "Trialing", "Canceled", "None"];

const when = (d) => {
  if (!d) return "—";
  try {
    return new Date(d).toLocaleDateString();
  } catch {
    return "—";
  }
};

const subStatus = (r) => String(r.subscription?.status || "NONE").toUpperCase();

export default function Tenants() {
  const { pushToast } = useStore();
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState("All");

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await api.providerTenantsMerged();
      setRows(Array.isArray(data) ? data : []);
    } catch (e) {
      setError(e.message || "Failed to load tenants");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const shown = useMemo(() => {
    return rows.filter((r) => {
      const matchesFilter =
        filter === "All" || subStatus(r) === filter.toUpperCase();
      const q = query.toLowerCase();
      const matchesQuery =
        !q ||
        String(r.name || "").toLowerCase().includes(q) ||
        String(r.adminEmail || "").toLowerCase().includes(q) ||
        String(r.emailDomain || "").toLowerCase().includes(q);
      return matchesFilter && matchesQuery;
    });
  }, [rows, filter, query]);

  const exportCsv = () => {
    downloadCsv("tenants.csv", shown, [
      { label: "Tenant", value: "name" },
      { label: "Admin email", value: (r) => r.adminEmail || "" },
      { label: "Members", value: (r) => r.members ?? 0 },
      { label: "Active members", value: (r) => r.activeMembers ?? 0 },
      { label: "Plan", value: (r) => r.subscription?.planName || "" },
      { label: "Status", value: (r) => r.subscription?.status || "" },
      { label: "Price monthly", value: (r) => r.subscription?.priceMonthly ?? "" },
      { label: "Created", value: (r) => r.createdAt || "" },
    ]);
    pushToast(`Exported ${shown.length} tenants to CSV`, "cyan");
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Tenants"
        subtitle="Every customer organization on AutoOps"
        actions={
          <SmallButton icon="doc" onClick={exportCsv} disabled={!shown.length}>
            Export CSV
          </SmallButton>
        }
      />
      <Toolbar
        placeholder="Search tenants…"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        right={FILTERS.map((f) => (
          <button
            key={f}
            onClick={() => setFilter(f)}
            className={`rounded-lg px-3 py-1.5 text-xs font-medium transition ${filter === f ? "bg-slate-50 text-slate-900" : "text-slate-500 hover:bg-slate-100 hover:text-slate-900"}`}
          >
            {f}
          </button>
        ))}
      />
      <Table
        loading={loading}
        error={error}
        onRetry={load}
        empty="No tenants yet. Tenants appear here as customers register."
        columns={[
          {
            key: "name",
            label: "Workspace",
            render: (r) => (
              <div>
                <Link
                  to={`/provider/tenants/${r.tenantId}`}
                  className="font-medium text-slate-900 hover:text-violet-600"
                >
                  {r.name || r.tenantId}
                </Link>
                {r.emailDomain && (
                  <p className="text-xs text-slate-500">{r.emailDomain}</p>
                )}
              </div>
            ),
          },
          {
            key: "adminEmail",
            label: "Admin",
            render: (r) => (
              <span className="text-slate-600">{r.adminEmail || "—"}</span>
            ),
          },
          {
            key: "members",
            label: "Members",
            render: (r) => (
              <span className="text-slate-600">
                {r.activeMembers ?? r.members ?? 0}/{r.members ?? 0}
              </span>
            ),
          },
          {
            key: "plan",
            label: "Plan",
            render: (r) =>
              r.subscription ? (
                <Chip>{r.subscription.planName || r.subscription.planCode}</Chip>
              ) : (
                <span className="text-slate-500">—</span>
              ),
          },
          {
            key: "status",
            label: "Status",
            render: (r) =>
              r.subscription ? (
                <StatusBadge
                  status={String(r.subscription.status || "").toLowerCase()}
                />
              ) : (
                <span className="text-xs text-slate-500">No subscription</span>
              ),
          },
          {
            key: "createdAt",
            label: "Created",
            render: (r) => (
              <span className="text-slate-500">{when(r.createdAt)}</span>
            ),
          },
          {
            key: "act",
            label: "",
            render: (r) => (
              <Link
                to={`/provider/tenants/${r.tenantId}`}
                className="text-sm text-violet-600 hover:text-violet-200"
              >
                View →
              </Link>
            ),
          },
        ]}
        rows={shown}
      />
    </div>
  );
}
