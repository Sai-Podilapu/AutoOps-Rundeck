import React, { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import {
  PageHeader,
  Card,
  StatusBadge,
  SmallButton,
  Skeleton,
} from "../../components/app/appui";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";
import { fmtDate, fmtDuration, badgeStatus } from "../../lib/format";
import { base } from "../../lib/base";

export default function ExecutionDetail() {
  const { id } = useParams();
  const { can, pushToast } = useStore();
  const [exec, setExec] = useState(null);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const canWrite = can("runWorkflow");

  const load = async () => {
    setLoading(true);
    setNotFound(false);
    try {
      const e = await api.get("executions", id);
      setExec(e);
    } catch {
      setNotFound(true);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  // Live-refresh while the run is still executing (log grows per step).
  useEffect(() => {
    if (!exec || !["queued", "running"].includes(badgeStatus(exec.status)))
      return undefined;
    const t = setTimeout(async () => {
      try {
        setExec(await api.get("executions", id));
      } catch {
        /* transient — next status render decides whether to retry */
      }
    }, 3000);
    return () => clearTimeout(t);
  }, [exec, id]);

  const cancel = async () => {
    try {
      await api.cancelExecution(id);
      pushToast("Execution cancelled", "red");
      load();
    } catch (e) {
      pushToast(e.message || "Could not cancel", "red");
    }
  };

  if (loading)
    return (
      <div className="animate-fade-up">
        <Skeleton className="h-4 w-24" />
        <Skeleton className="mt-4 h-8 w-72" />
        <Card className="mt-6 h-40 p-6">
          <Skeleton className="h-5 w-40" />
        </Card>
      </div>
    );

  if (notFound || !exec)
    return (
      <div className="animate-fade-up">
        <PageHeader
          title="Execution not found"
          subtitle="This execution isn’t available."
        />
        <Card className="p-10 text-center text-sm text-slate-500">
          Nothing here.{" "}
          <Link
            to={`${base()}/executions`}
            className="text-slate-900 hover:underline"
          >
            Back to executions
          </Link>
        </Card>
      </div>
    );

  const active = ["queued", "running"].includes(badgeStatus(exec.status));

  return (
    <div className="animate-fade-up">
      <Link
        to={`${base()}/executions`}
        className="text-sm text-slate-500 transition hover:text-slate-900"
      >
        ← Executions
      </Link>
      <PageHeader
        title={exec.name || `Run ${String(exec.id).slice(0, 8)}`}
        subtitle={exec.trigger ? `Trigger: ${exec.trigger}` : "Manual run"}
        actions={
          canWrite && active ? (
            <SmallButton icon="bolt" variant="primary" onClick={cancel}>
              Abort
            </SmallButton>
          ) : null
        }
      />
      <div className="mb-6 flex flex-wrap gap-3">
        {[
          { k: "Status", v: <StatusBadge status={badgeStatus(exec.status)} /> },
          { k: "Trigger", v: exec.trigger || "manual" },
          { k: "Duration", v: fmtDuration(exec.durationMs) },
          { k: "Started", v: fmtDate(exec.startedAt || exec.createdAt) },
          { k: "Finished", v: fmtDate(exec.finishedAt) },
        ].map((m) => (
          <Card key={m.k} className="px-4 py-3">
            <p className="text-[11px] text-slate-500">{m.k}</p>
            <div className="mt-1 text-sm font-medium text-slate-900">{m.v}</div>
          </Card>
        ))}
      </div>
      <Card className="p-6">
        <h3 className="mb-4 text-sm font-semibold text-slate-900">
          Output log
        </h3>
        <div className="rounded-lg border border-slate-200 bg-slate-900/30 p-4 font-mono text-xs text-slate-600">
          {exec.log ? (
            <pre className="whitespace-pre-wrap">{exec.log}</pre>
          ) : exec.error ? (
            <span className="text-red-600">{exec.error}</span>
          ) : (
            <span className="text-slate-500">
              No log output captured for this run.
            </span>
          )}
        </div>
      </Card>
    </div>
  );
}
