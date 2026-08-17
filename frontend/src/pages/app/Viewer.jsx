import React, { useState, useEffect } from "react";
import {
  PageHeader,
  Card,
  StatCard,
  Table,
  StatusBadge,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import { api } from "../../lib/api";
import ThroughputChart from "../../components/app/ThroughputChart";

export default function Viewer() {
  const [executions, setExecutions] = useState([]);
  const [workflows, setWorkflows] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    Promise.all([
      api.list("executions").catch(() => []),
      api.list("workflows").catch(() => []),
    ]).then(([execs, wfs]) => {
      setLoading(false);
      setExecutions(Array.isArray(execs) ? execs : []);
      setWorkflows(Array.isArray(wfs) ? wfs : []);
    });
  }, []);

  // Compute KPIs from real data
  const successCount = executions.filter((e) => e.status === "success").length;
  const successRate = executions.length > 0 ? ((successCount / executions.length) * 100).toFixed(1) + "%" : "\u2014";
  const kpis = [
    { label: "Executions today", value: String(executions.length), icon: "play", tone: "cyan" },
    { label: "Success rate", value: successRate, icon: "shield", tone: "emerald" },
    { label: "Active workflows", value: String(workflows.length), icon: "trail", tone: "violet" },
    { label: "Running now", value: String(executions.filter((e) => e.status === "running").length), icon: "clock", tone: "cyan" },
  ];

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Viewer Console"
        subtitle="Read-only overview of automation activity and health"
      />

      <Card className="mb-6 flex items-center gap-3 border-slate-300 bg-slate-100 p-4 text-sm text-slate-900">
        <Icon name="lock" size={18} /> You have{" "}
        <b className="mx-1">read-only</b> access. Running jobs, editing
        workflows, and approvals are disabled for your role.
      </Card>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {kpis.map((k) => (
          <StatCard key={k.label} {...k} />
        ))}
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-[1.5fr_1fr]">
        <div>
          <h3 className="mb-3 text-sm font-semibold text-slate-900">
            Recent executions
          </h3>
          <Table
            columns={[
              {
                key: "name",
                label: "Execution",
                render: (r) => (
                  <div>
                    <p className="font-mono text-sm text-slate-900">{r.name}</p>
                    <p className="text-xs text-slate-500">{r.workflow}</p>
                  </div>
                ),
              },
              { key: "duration", label: "Duration" },
              { key: "by", label: "By" },
              {
                key: "status",
                label: "Status",
                render: (r) => <StatusBadge status={r.status} />,
              },
            ]}
            rows={executions}
          />
        </div>
        <div className="space-y-6">
          <ThroughputChart
            executions={executions}
            loading={loading}
            defaultRange="24h"
            height="h-32"
            className="p-5"
          />
          <div>
            <h3 className="mb-3 text-sm font-semibold text-slate-900">
              Workflows
            </h3>
            <Card className="divide-y divide-slate-200">
              {workflows.map((w) => (
                <div
                  key={w.id}
                  className="flex items-center justify-between px-5 py-3"
                >
                  <div>
                    <p className="text-sm text-slate-900">{w.name}</p>
                    <p className="text-xs text-slate-500">
                      {w.steps} steps · {w.runs} runs
                    </p>
                  </div>
                  <StatusBadge status={w.status} />
                </div>
              ))}
            </Card>
          </div>
        </div>
      </div>
    </div>
  );
}
