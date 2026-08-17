import React, { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import {
  PageHeader,
  Card,
  StatusBadge,
  Table,
  SmallButton,
  Chip,
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

export default function TenantDetail() {
  const { id } = useParams();
  const [tenant, setTenant] = useState(null);
  const [usage, setUsage] = useState(null);
  const [payments, setPayments] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const [tenants, usageRows, invoices] = await Promise.all([
        api.providerTenantsMerged(),
        api.providerUsage().catch(() => []),
        api.providerInvoices().catch(() => []),
      ]);
      const t = (tenants || []).find((x) => String(x.tenantId) === String(id));
      setTenant(t || null);
      setUsage(
        (usageRows || []).find((u) => String(u.tenantId) === String(id)) ||
          null,
      );
      setPayments(
        (invoices || []).filter((p) => String(p.tenantId) === String(id)),
      );
    } catch (e) {
      setError(e.message || "Could not load tenant");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  if (loading)
    return (
      <div className="animate-fade-up">
        <PageHeader title="Tenant" subtitle="Loading…" />
        <Card className="p-10 text-center text-sm text-slate-500">
          Loading tenant…
        </Card>
      </div>
    );

  if (error || !tenant)
    return (
      <div className="animate-fade-up">
        <PageHeader
          title="Tenant not found"
          subtitle={error || "This tenant isn’t available."}
        />
        <Card className="p-10 text-center text-sm text-slate-500">
          {error ? (
            <button
              onClick={load}
              className="text-slate-900 hover:underline"
            >
              Try again
            </button>
          ) : (
            <>Nothing here yet. </>
          )}{" "}
          <Link
            to="/provider/tenants"
            className="text-slate-900 hover:underline"
          >
            Back to tenants
          </Link>
        </Card>
      </div>
    );

  const sub = tenant.subscription;
  const usageStats = [
    ["Projects", usage?.projects],
    ["Workflows", usage?.workflows],
    ["Jobs", usage?.jobs],
    ["Runs (30d)", usage?.runs30d],
    ["Failed runs (30d)", usage?.failedRuns30d],
  ];

  return (
    <div className="animate-fade-up">
      <Link
        to="/provider/tenants"
        className="text-sm text-slate-500 transition hover:text-violet-600"
      >
        ← Tenants
      </Link>
      <PageHeader
        title={tenant.name || tenant.tenantId}
        subtitle={[
          tenant.adminEmail,
          tenant.emailDomain,
          tenant.createdAt ? `since ${when(tenant.createdAt)}` : null,
        ]
          .filter(Boolean)
          .join(" · ")}
        actions={
          <SmallButton icon="pulse" onClick={load}>
            Refresh
          </SmallButton>
        }
      />
      <div className="mb-6 flex flex-wrap gap-3">
        {[
          [
            "Plan",
            sub ? (
              <Chip>{sub.planName || sub.planCode}</Chip>
            ) : (
              <span className="text-slate-500">No subscription</span>
            ),
          ],
          [
            "Status",
            sub ? (
              <StatusBadge status={String(sub.status || "").toLowerCase()} />
            ) : (
              <span className="text-slate-500">—</span>
            ),
          ],
          [
            "Price",
            sub ? (
              <span className="text-emerald-600">
                ${Number(sub.priceMonthly || 0).toLocaleString()}/mo
              </span>
            ) : (
              <span className="text-slate-500">—</span>
            ),
          ],
          [
            "Members",
            `${tenant.activeMembers ?? tenant.members ?? 0}/${tenant.members ?? 0}`,
          ],
          [
            "Period ends",
            sub?.currentPeriodEnd ? when(sub.currentPeriodEnd) : "—",
          ],
        ].map(([k, v], i) => (
          <Card key={i} className="px-4 py-3">
            <p className="text-[11px] text-slate-500">{k}</p>
            <div className="mt-1 text-sm font-medium text-slate-900">{v}</div>
          </Card>
        ))}
      </div>

      {sub?.cancelAtPeriodEnd && (
        <p className="mb-6 rounded-lg border border-amber-400/30 bg-amber-400/10 px-3 py-2 text-xs text-amber-600">
          Subscription is set to cancel at the end of the current period
          {sub.currentPeriodEnd ? ` (${when(sub.currentPeriodEnd)})` : ""}.
        </p>
      )}

      <div className="grid gap-6 lg:grid-cols-3">
        <Card className="p-6 lg:col-span-1">
          <h3 className="mb-4 text-sm font-semibold text-slate-900">Usage</h3>
          {usage ? (
            <dl className="space-y-2 text-sm">
              {usageStats.map(([k, v]) => (
                <div key={k} className="flex justify-between">
                  <dt className="text-slate-500">{k}</dt>
                  <dd className="text-slate-700">
                    {Number(v || 0).toLocaleString()}
                  </dd>
                </div>
              ))}
            </dl>
          ) : (
            <p className="text-sm text-slate-500">No usage data yet.</p>
          )}
        </Card>
        <div className="lg:col-span-2">
          <h3 className="mb-3 text-sm font-semibold text-slate-900">
            Payments
          </h3>
          <Table
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
              { key: "planCode", label: "Plan" },
              {
                key: "amountCents",
                label: "Amount",
                render: (r) => (
                  <span className="font-medium text-slate-900">
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
            rows={payments}
          />
        </div>
      </div>
    </div>
  );
}
