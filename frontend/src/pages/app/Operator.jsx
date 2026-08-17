import React, { useEffect, useState } from "react";
import {
  PageHeader,
  Card,
  StatCard,
  Table,
  StatusBadge,
  SmallButton,
  Chip,
  ConfirmModal,
  Pagination,
} from "../../components/app/appui";
import { useStore } from "../../store/store";
import { api } from "../../lib/api";

export default function Operator() {
  const { can, pushToast } = useStore();
  const canRun = can("runWorkflow");
  const canApprove = can("approve");

  const [scripts, setScripts] = useState([]);
  const [selectedScript, setSelectedScript] = useState("");
  const [executions, setExecutions] = useState([]);
  const [schedules, setSchedules] = useState([]);
  const [confirmRerun, setConfirmRerun] = useState(false);
  const [confirmAdhoc, setConfirmAdhoc] = useState(false);
  const [pageExecutions, setPageExecutions] = useState(1);
  const [pageSchedules, setPageSchedules] = useState(1);
  const pageSize = 5;

  useEffect(() => {
    api.listLibrary()
      .then((rows) => {
        const runnable = (Array.isArray(rows) ? rows : []).filter(
          (i) => i.type === "script" || i.type === "workflow",
        );
        setScripts(runnable);
        if (runnable[0]) setSelectedScript(runnable[0].id);
      })
      .catch(() => {});
    Promise.all([
      api.list("executions").catch(() => []),
      api.list("schedules").catch(() => []),
    ]).then(([execs, scheds]) => {
      setExecutions(Array.isArray(execs) ? execs : []);
      setSchedules(Array.isArray(scheds) ? scheds : []);
    });
  }, []);

  const runSelected = () => {
    const item = scripts.find((s) => s.id === selectedScript);
    if (!item) {
      pushToast("Select a script or workflow to run first", "amber");
      return;
    }
    pushToast(`Running \u201c${item.title}\u201d\u2026`, "emerald");
  };

  const failed = executions.filter((e) => e.status === "failed");
  const live = executions.filter(
    (e) => e.status === "queued" || e.status === "running",
  );

  const paginatedExecutions = executions.slice((pageExecutions - 1) * pageSize, pageExecutions * pageSize);
  const paginatedSchedules = schedules.slice((pageSchedules - 1) * pageSize, pageSchedules * pageSize);

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Operator Console"
        subtitle="Run, monitor, and act on automations across your projects"
        actions={
          canRun ? (
            <>
              <SmallButton
                icon="play"
                onClick={() => setConfirmRerun(true)}
              >
                Re-run failed
              </SmallButton>
              <SmallButton
                icon="bolt"
                variant="primary"
                onClick={() => setConfirmAdhoc(true)}
              >
                Ad-hoc run
              </SmallButton>
            </>
          ) : (
            <Chip>Read-only role</Chip>
          )
        }
      />

      {canRun && (
        <Card className="mb-6 flex flex-col gap-3 p-5 sm:flex-row sm:items-end sm:justify-between">
          <div className="flex-1">
            <p className="text-sm font-semibold text-slate-900">Quick run</p>
            <p className="mb-2 text-xs text-slate-500">
              Pick a script or workflow from your library and run it now.
            </p>
            <select
              value={selectedScript}
              onChange={(e) => setSelectedScript(e.target.value)}
              className="w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2.5 text-sm text-slate-900 outline-none focus:border-slate-300 sm:max-w-md"
            >
              {scripts.length === 0 && (
                <option value="">
                  No runnable items yet — import from Library
                </option>
              )}
              {scripts.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.title} · {s.type}
                </option>
              ))}
            </select>
          </div>
          <SmallButton
            icon="play"
            variant="primary"
            onClick={runSelected}
            disabled={!selectedScript}
          >
            Run now
          </SmallButton>
        </Card>
      )}

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <StatCard
          label="Running now"
          value={String(live.length)}
          icon="play"
          tone="cyan"
        />
        <StatCard
          label="Needs attention"
          value={String(failed.length)}
          icon="bolt"
          tone="amber"
        />
        <StatCard
          label="Active schedules"
          value={String(schedules.filter((s) => s.status === "enabled").length)}
          icon="clock"
          tone="emerald"
        />
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-2 items-stretch">
        <Card className="flex h-full flex-col p-6">
          <div className="mb-4 flex items-center justify-between">
            <h3 className="text-sm font-semibold text-slate-900">
              Live run queue
            </h3>
            <span className="flex items-center gap-1.5 text-xs text-slate-500">
              <span className="h-1.5 w-1.5 animate-pulse-dot rounded-full bg-slate-100" />{" "}
              auto-refresh
            </span>
          </div>
          <div className="flex-1 overflow-hidden rounded-lg border border-slate-200">
            <Table
              cardClass="border-0 shadow-none !rounded-none"
            columns={[
              {
                key: "name",
                label: "Execution",
                render: (r) => (
                  <div>
                    <p className="font-mono text-sm text-slate-900">{r.name}</p>
                    <p className="text-xs text-slate-500">
                      #{r.id} · {r.workflow}
                    </p>
                  </div>
                ),
              },
              { key: "node", label: "Node" },
              {
                key: "status",
                label: "Status",
                render: (r) => <StatusBadge status={r.status} />,
              },
              {
                key: "act",
                label: "",
                render: (r) =>
                  canRun ? (
                    <button
                      onClick={() => pushToast(`Re-queued ${r.name}`, "cyan")}
                      className="text-xs text-slate-900 hover:text-slate-900"
                    >
                      Re-run
                    </button>
                  ) : null,
              },
            ]}
            rows={paginatedExecutions}
          />
          </div>
          <div className="mt-4">
            <Pagination
              page={pageExecutions}
              pageSize={pageSize}
              totalItems={executions.length}
              onPageChange={setPageExecutions}
            />
          </div>
        </Card>

        <Card className="flex h-full flex-col p-6">
          <h3 className="mb-4 text-sm font-semibold text-slate-900">
            Upcoming schedules
          </h3>
          <div className="flex-1 overflow-hidden rounded-lg border border-slate-200">
            <div className="divide-y divide-slate-200">
              {paginatedSchedules.map((s) => (
              <div
                key={s.id}
                className="flex items-center justify-between px-5 py-3"
              >
                <div>
                  <p className="text-sm text-slate-900">{s.job}</p>
                  <p className="font-mono text-xs text-slate-500">{s.cron}</p>
                </div>
                <div className="flex items-center gap-3">
                  <span className="text-xs text-slate-500">{s.next}</span>
                  <StatusBadge status={s.status} />
                </div>
              </div>
              ))}
            </div>
          </div>
          <div className="mt-4">
            <Pagination
              page={pageSchedules}
              pageSize={pageSize}
              totalItems={schedules.length}
              onPageChange={setPageSchedules}
            />
          </div>
        </Card>
      </div>

      <ConfirmModal
        open={confirmRerun}
        title="Re-run failed executions"
        message={`You are about to re-run ${failed.length} failed execution(s): ${failed.map(e => e.name).join(", ")}. Do you want to proceed?`}
        tone="neutral"
        confirmLabel="Re-run"
        onClose={() => setConfirmRerun(false)}
        onConfirm={() => {
          setConfirmRerun(false);
          pushToast("Re-running all failed executions…", "cyan");
        }}
      />

      <ConfirmModal
        open={confirmAdhoc}
        title="Confirm Ad-hoc run"
        message={`You are about to trigger an ad-hoc run for the selected script: ${scripts.find(s => s.id === selectedScript)?.title || "None selected"}. Do you want to proceed?`}
        tone="neutral"
        confirmLabel="Run now"
        onClose={() => setConfirmAdhoc(false)}
        onConfirm={() => {
          setConfirmAdhoc(false);
          runSelected();
        }}
      />
    </div>
  );
}
