import React, { useState, useEffect } from "react";
import { useParams } from "react-router-dom";
import {
  PageHeader,
  Toolbar,
  Table,
  SmallButton,
  Pagination,
} from "../../components/app/appui";
import { api } from "../../lib/api";
import UpgradeNotice from "../../components/app/UpgradeNotice";

export default function Audit() {
  const { pid } = useParams();
  const [auditEvents, setAuditEvents] = useState([]);
  const [loading, setLoading] = useState(true);
  const [gateError, setGateError] = useState(null);
  const [needsUpgrade, setNeedsUpgrade] = useState(false);
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(1);
  const pageSize = 10;

  useEffect(() => {
    api
      .list("audit", pid)
      .then((rows) => {
        setAuditEvents(Array.isArray(rows) ? rows : []);
        setLoading(false);
      })
      .catch((e) => {
        if (e?.data?.error === "feature_not_in_plan") {
          setNeedsUpgrade(true);
        } else {
          setGateError(e?.message || "Could not load the audit log");
        }
        setLoading(false);
      });
  }, [pid]);

  const filtered = query
    ? auditEvents.filter((e) =>
        [e.actor, e.action, e.resource, e.detail]
          .join(" ")
          .toLowerCase()
          .includes(query.toLowerCase()),
      )
    : auditEvents;
  const paginated = filtered.slice((page - 1) * pageSize, page * pageSize);

  const exportJson = () => {
    const blob = new Blob([JSON.stringify(auditEvents, null, 2)], {
      type: "application/json",
    });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "autoops-audit-log.json";
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Audit Log"
        subtitle="Attributed record of every action in your workspace"
        actions={
          <SmallButton icon="doc" onClick={exportJson} disabled={!auditEvents.length}>
            Export
          </SmallButton>
        }
      />

      {needsUpgrade ? (
        <UpgradeNotice feature="Audit log" plan="Team" />
      ) : gateError ? (
        <div className="rounded-xl border border-amber-500/30 bg-amber-500/10 p-6 text-sm text-slate-700">
          <p className="font-semibold text-slate-900">Audit log unavailable</p>
          <p className="mt-1">{gateError}</p>
        </div>
      ) : (
        <>
          <Toolbar
            placeholder="Search events…"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setPage(1);
            }}
          />
          <Table
            columns={[
              {
                key: "time",
                label: "Time",
                render: (r) => (
                  <span className="font-mono text-xs text-slate-500">
                    {r.time}
                  </span>
                ),
              },
              {
                key: "actor",
                label: "Actor",
                render: (r) => (
                  <span className="font-medium text-slate-900">{r.actor}</span>
                ),
              },
              {
                key: "action",
                label: "Action",
                render: (r) => (
                  <span className="font-mono text-xs text-slate-900">
                    {r.action}
                  </span>
                ),
              },
              {
                key: "resource",
                label: "Resource",
                render: (r) => (
                  <span className="text-slate-600">{r.resource}</span>
                ),
              },
              {
                key: "detail",
                label: "Detail",
                render: (r) => (
                  <span className="text-xs text-slate-500">{r.detail}</span>
                ),
              },
            ]}
            rows={paginated}
            loading={loading}
            empty="No audit events yet"
          />
          <div className="mt-4">
            <Pagination
              page={page}
              pageSize={pageSize}
              totalItems={filtered.length}
              onPageChange={setPage}
            />
          </div>
        </>
      )}
    </div>
  );
}
