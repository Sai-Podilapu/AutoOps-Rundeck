import React, { useState, useEffect } from "react";
import { Link } from "react-router-dom";
import {
  PageHeader,
  StatCard,
  Card,
  StatusBadge,
  Table,
  SmallButton,
  Pagination,
} from "../../components/app/appui";
import ThroughputChart from "../../components/app/ThroughputChart";
import { api } from "../../lib/api";

export default function Dashboard() {
  const [executions, setExecutions] = useState([]);
  const [nodes, setNodes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [page, setPage] = useState(1);
  const pageSize = 5;

  useEffect(() => {
    Promise.all([
      api.list("executions").catch(() => []),
      api.list("nodes").catch(() => []),
    ]).then(([execs, nds]) => {
      setExecutions(Array.isArray(execs) ? execs : []);
      setNodes(Array.isArray(nds) ? nds : []);
      setLoading(false);
    });
  }, []);

  const successCount = executions.filter((e) => e.status === "success").length;
  const failedCount = executions.filter((e) => e.status === "failed").length;
  const runningCount = executions.filter((e) => e.status === "running" || e.status === "queued").length;
  const successRate = executions.length > 0 ? ((successCount / executions.length) * 100).toFixed(1) + "%" : "—";

  const kpis = [
    { label: "Recent executions", value: String(executions.length), icon: "play", tone: "cyan" },
    { label: "Success rate", value: successRate, icon: "shield", tone: "emerald" },
    { label: "Failed", value: String(failedCount), icon: "warning", tone: "red" },
    { label: "Running now", value: String(runningCount), icon: "clock", tone: "cyan" },
  ];

  const paginatedExecutions = executions.slice((page - 1) * pageSize, page * pageSize);

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Dashboard"
        subtitle="Live overview of your automation platform"
        actions={
          <>
            <SmallButton icon="terminal">Console</SmallButton>
            <SmallButton icon="plus" variant="primary">
              New Job
            </SmallButton>
          </>
        }
      />

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {kpis.map((k) => (
          <StatCard key={k.label} {...k} />
        ))}
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <ThroughputChart
          executions={executions}
          loading={loading}
          className="p-6 lg:col-span-2"
        />

        <Card className="p-6">
          <h3 className="mb-4 text-sm font-semibold text-slate-900">
            Node health
          </h3>
          <div className="space-y-3">
            {nodes.slice(0, 5).map((n) => (
              <div key={n.id} className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <span
                    className={`h-2 w-2 rounded-full ${n.status === "online" ? "bg-emerald-400" : "bg-slate-300"}`}
                  />
                  <span className="text-sm text-slate-600">{n.name}</span>
                </div>
                <span className="text-xs capitalize text-slate-500">
                  {n.status || "unknown"}
                </span>
              </div>
            ))}
            {nodes.length === 0 && (
              <p className="text-sm text-slate-500">
                No nodes registered yet.
              </p>
            )}
          </div>
          <Link
            to="/app/projects"
            className="mt-4 inline-block text-xs font-medium text-slate-900 hover:underline"
          >
            View all nodes →
          </Link>
        </Card>
      </div>

      <div className="mt-6">
        <div className="mb-3 flex items-center justify-between">
          <h3 className="text-sm font-semibold text-slate-900">
            Recent executions
          </h3>
          <Link
            to="/app/executions"
            className="text-xs font-medium text-slate-900 hover:underline"
          >
            View all →
          </Link>
        </div>
        <Table
          columns={[
            {
              key: "id",
              label: "#",
              render: (r) => (
                <span className="font-mono text-slate-500">{r.id}</span>
              ),
            },
            {
              key: "name",
              label: "Execution",
              render: (r) => (
                <Link
                  to={`/app/executions/${r.id}`}
                  className="font-medium text-slate-900 hover:text-slate-900"
                >
                  {r.name}
                </Link>
              ),
            },
            { key: "workflow", label: "Workflow" },
            {
              key: "status",
              label: "Status",
              render: (r) => <StatusBadge status={r.status} />,
            },
            {
              key: "duration",
              label: "Duration",
              render: (r) => <span className="font-mono">{r.duration}</span>,
            },
            {
              key: "by",
              label: "Triggered by",
              render: (r) => <span className="text-slate-500">{r.by}</span>,
            },
          ]}
          rows={paginatedExecutions}
        />
        <div className="mt-4">
          <Pagination
            page={page}
            pageSize={pageSize}
            totalItems={executions.length}
            onPageChange={setPage}
          />
        </div>
      </div>
    </div>
  );
}
