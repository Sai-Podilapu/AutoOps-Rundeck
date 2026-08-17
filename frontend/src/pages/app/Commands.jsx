import React, { useState, useEffect } from "react";
import {
  PageHeader,
  Card,
  Table,
  StatusBadge,
  SmallButton,
} from "../../components/app/appui";
import { useStore } from "../../store/store";
import { api } from "../../lib/api";

const mapCommand = (c) => ({
  id: c.id,
  cmd: c.command,
  nodes: c.target || "platform-runner",
  by: c.dispatchedBy || "—",
  time: c.createdAt ? new Date(c.createdAt).toLocaleString() : "",
  status: String(c.status || "").toLowerCase() === "succeeded" ? "success" : "failed",
  output: c.output || "",
});

export default function Commands() {
  const { pushToast } = useStore();
  const [commandHistory, setCommandHistory] = useState([]);
  const [loading, setLoading] = useState(true);
  const [command, setCommand] = useState("");
  const [dispatching, setDispatching] = useState(false);
  const [lastResult, setLastResult] = useState(null);

  const load = () => {
    api
      .listCommands()
      .then((rows) => {
        setCommandHistory((Array.isArray(rows) ? rows : []).map(mapCommand));
        setLoading(false);
      })
      .catch(() => setLoading(false));
  };

  useEffect(() => {
    load();
  }, []);

  const dispatch = async () => {
    if (!command.trim() || dispatching) return;
    setDispatching(true);
    setLastResult(null);
    try {
      const record = await api.dispatchCommand(command.trim());
      const mapped = mapCommand(record);
      setLastResult(mapped);
      pushToast(
        mapped.status === "success" ? "Command succeeded" : "Command failed",
        mapped.status === "success" ? "emerald" : "red",
      );
      setCommand("");
      load();
    } catch (e) {
      pushToast(e.message || "Could not dispatch the command", "red");
    } finally {
      setDispatching(false);
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Commands"
        subtitle="Run an ad-hoc command on the platform runner — output lands in history"
      />
      <Card className="mb-6 p-5">
        <label className="text-xs font-medium text-slate-500">Command</label>
        <div className="mt-2 flex flex-col gap-3 sm:flex-row">
          <div className="flex flex-1 items-center gap-2 rounded-lg border border-slate-200 bg-slate-900/30 px-3 font-mono text-sm">
            <span className="text-emerald-600">$</span>
            <input
              value={command}
              onChange={(e) => setCommand(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && dispatch()}
              placeholder="uptime && df -h"
              className="w-full bg-transparent py-2.5 text-slate-900 outline-none"
            />
          </div>
          <span className="inline-flex items-center rounded-lg border border-slate-200 bg-slate-50 px-3 py-2.5 text-sm text-slate-600">
            Platform runner
          </span>
          <SmallButton
            icon="play"
            variant="primary"
            onClick={dispatch}
            disabled={dispatching || !command.trim()}
          >
            {dispatching ? "Running…" : "Dispatch"}
          </SmallButton>
        </div>
        {lastResult && (
          <pre className="mt-4 max-h-56 overflow-auto rounded-lg border border-slate-200 bg-slate-50 p-3 font-mono text-xs text-slate-700 whitespace-pre-wrap">
            {lastResult.output || "(no output)"}
          </pre>
        )}
      </Card>
      <h3 className="mb-3 text-sm font-semibold text-slate-900">
        Command history
      </h3>
      <Table
        loading={loading}
        empty="No commands dispatched yet."
        columns={[
          {
            key: "cmd",
            label: "Command",
            render: (r) => (
              <span className="font-mono text-xs text-slate-700">{r.cmd}</span>
            ),
          },
          {
            key: "nodes",
            label: "Target",
            render: (r) => <span className="text-slate-500">{r.nodes}</span>,
          },
          {
            key: "by",
            label: "By",
            render: (r) => <span className="text-slate-500">{r.by}</span>,
          },
          {
            key: "time",
            label: "Time",
            render: (r) => <span className="text-slate-500">{r.time}</span>,
          },
          {
            key: "status",
            label: "Status",
            render: (r) => <StatusBadge status={r.status} />,
          },
        ]}
        rows={commandHistory}
        onRowClick={(r) => setLastResult(r)}
      />
    </div>
  );
}
