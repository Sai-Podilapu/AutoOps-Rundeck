import React, { useEffect, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import {
  PageHeader,
  Toolbar,
  Table,
  StatusBadge,
  SmallButton,
  Chip,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import { useCollection } from "../../lib/useCollection";
import { useStore } from "../../store/store";
import { fmtDate, fmtDuration, badgeStatus } from "../../lib/format";
import { base } from "../../lib/base";
import { api } from "../../lib/api";

export default function Executions() {
  const { pid } = useParams();
  const navigate = useNavigate();
  const { can, pushToast } = useStore();
  const canRun = can("runWorkflow");

  // ?jobId=… scopes the page to ONE job's runs — that is what the History
  // button on a job opens. Without it this stays the project-wide list.
  const [searchParams] = useSearchParams();
  const jobId = searchParams.get("jobId");
  const [jobName, setJobName] = useState(null);

  // Narrowed by the SERVER, not here: the endpoint answers with the newest 200
  // runs, so filtering a project-wide page in the browser would lose this
  // job's older runs behind a noisier neighbour's.
  const { rows, loading, error, reload } = useCollection(
    "executions",
    pid,
    jobId ? { targetType: "JOB", targetId: jobId } : undefined,
  );

  useEffect(() => {
    if (!jobId) {
      setJobName(null);
      return undefined;
    }
    let alive = true;
    // Named from the job itself, not from a run: a job with no runs yet still
    // has to say whose history is empty.
    api
      .get("jobs", jobId)
      .then((j) => {
        if (alive) setJobName(j?.name || null);
      })
      .catch(() => {
        if (alive) setJobName(null);
      });
    return () => {
      alive = false;
    };
  }, [jobId]);

  const cancelRun = async (id) => {
    try {
      await api.cancelExecution(id);
      pushToast("Run cancellation requested", "amber");
      reload();
    } catch (e) {
      pushToast(e.message || "Could not cancel run", "red");
    }
  };

  const [filterType, setFilterType] = useState("all");

  const filteredRows = rows.filter((r) => {
    if (filterType === "jobs") return !!r.job;
    if (filterType === "workflows") return !!r.workflow;
    return true;
  });
  return (
    <div className="animate-fade-up">
      {jobId && (
        <Link
          to={`${base()}/jobs/${jobId}`}
          className="mb-3 inline-flex items-center gap-1.5 text-sm text-slate-500 transition hover:text-slate-900"
        >
          ← {jobName || "Back to job"}
        </Link>
      )}
      <PageHeader
        title={jobId ? `${jobName || "Job"} — run history` : "Execution history"}
        subtitle={
          jobId
            ? "Every run of this job, newest first"
            : "Every run across this project’s jobs and workflows"
        }
        actions={
          jobId ? (
            <Link to={`${base()}/executions`}>
              <SmallButton icon="list">All runs in this project</SmallButton>
            </Link>
          ) : null
        }
      />
      <Toolbar
        placeholder="Search executions…"
        right={
          <>
            {/* Scoped to one job, the job/workflow selector says nothing. */}
            {!jobId && (
              <select
                value={filterType}
                onChange={(e) => setFilterType(e.target.value)}
                className="rounded-lg border border-slate-200 bg-slate-50 px-3 py-1.5 text-sm text-slate-700 outline-none transition hover:border-blue-500 focus:border-slate-300"
              >
                <option value="all">All types</option>
                <option value="jobs">Jobs</option>
                <option value="workflows">Workflows</option>
              </select>
            )}
            <Chip>{filteredRows.length} runs</Chip>
          </>
        }
      />
      <Table
        loading={loading}
        error={error}
        onRetry={reload}
        onRowClick={(r) => navigate(`${base()}/executions/${r.id}`)}
        empty={
          jobId
            ? "This job hasn’t run yet. Its runs will appear here once it does."
            : "No executions yet. Runs will appear here as jobs and workflows execute."
        }
        columns={[
          {
            key: "name",
            label: "Run",
            render: (r) => (
              <Link
                to={`${base()}/executions/${r.id}`}
                className="font-medium text-slate-900 hover:text-slate-900"
              >
                {r.name || `Run ${String(r.id).slice(0, 6)}`}
              </Link>
            ),
          },
          {
            key: "type",
            label: "Type",
            render: (r) => {
              const type = r.workflow ? "Workflow" : r.job ? "Job" : "Execution";
              const target = r.workflow || r.job || "Unknown";
              return (
                <div>
                  <span className="block text-sm font-medium text-slate-900">{type}</span>
                  <span className="block text-xs text-slate-500">{target}</span>
                </div>
              );
            }
          },
          {
            key: "status",
            label: "Status",
            render: (r) => <StatusBadge status={badgeStatus(r.status)} />,
          },
          {
            key: "trigger",
            label: "Trigger",
            render: (r) => (
              <span className="text-slate-500">{r.trigger || "manual"}</span>
            ),
          },
          {
            key: "durationMs",
            label: "Duration",
            render: (r) => (
              <span className="font-mono text-xs text-slate-500">
                {fmtDuration(r.durationMs)}
              </span>
            ),
          },
          {
            key: "startedAt",
            label: "Started",
            render: (r) => (
              <span className="text-slate-500">
                {fmtDate(r.startedAt || r.createdAt)}
              </span>
            ),
          },
          {
            key: "act",
            label: "",
            render: (r) => {
              const live = ["queued", "running"].includes(
                String(r.status || "").toLowerCase(),
              );
              return (
                <div
                  className="flex items-center justify-end gap-2"
                  onClick={(e) => e.stopPropagation()}
                >
                  <SmallButton
                    icon="eye"
                    onClick={() => navigate(`${base()}/executions/${r.id}`)}
                  >
                    View
                  </SmallButton>
                  {canRun && live && (
                    <button
                      onClick={() => cancelRun(r.id)}
                      aria-label="Cancel Run"
                      className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3.5 py-2 text-sm font-semibold text-slate-900 transition duration-300 hover:border-red-500 hover:bg-red-500 hover:text-white"
                    >
                      <Icon name="bolt" size={16} />
                      Cancel
                    </button>
                  )}
                </div>
              );
            },
          },
        ]}
        rows={filteredRows}
      />


    </div>
  );
}
