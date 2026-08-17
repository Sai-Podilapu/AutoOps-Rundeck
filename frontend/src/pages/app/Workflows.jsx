import React, { useState } from "react";
import { useParams } from "react-router-dom";
import {
  PageHeader,
  Toolbar,
  Table,
  StatusBadge,
  SmallButton,
  Chip,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import RunInputsDialog from "../../components/app/RunInputsDialog";
import { useCollection } from "../../lib/useCollection";
import { useStore } from "../../store/store";
import { fmtDate } from "../../lib/format";
import { api } from "../../lib/api";

const stateBadge = (s) => {
  const v = String(s || "").toUpperCase();
  if (v === "ACTIVE") return "active";
  if (v === "PAUSED") return "disabled";
  return "draft";
};

function SuccessBar({ value }) {
  const pct = Math.max(0, Math.min(100, Number(value) || 0));
  const fillStyle = { width: pct + "%" };
  const tone =
    pct >= 90 ? "bg-emerald-500" : pct >= 60 ? "bg-amber-500" : "bg-red-500";
  return (
    <div className="flex items-center gap-2">
      <div className="h-1.5 w-24 overflow-hidden rounded-full bg-slate-100">
        <div className={`h-full rounded-full ${tone}`} style={fillStyle} />
      </div>
      <span className="font-mono text-xs text-slate-500">{pct}%</span>
    </div>
  );
}

export default function Workflows() {
  const { pid } = useParams();
  const { can, pushToast } = useStore();
  const { rows, loading, error, reload } = useCollection("workflows", pid);
  const canRun = can("runWorkflow");
  /** {row, fields} while the input form is open; null when nothing is pending. */
  const [prompt, setPrompt] = useState(null);
  /** Workflow id whose input schema is being fetched — disables just that row. */
  const [asking, setAsking] = useState(null);
  const [starting, setStarting] = useState(false);

  const togglePaused = async (row) => {
    try {
      await api.setWorkflowEnabled(row.id, !row.active);
      pushToast(row.active ? `"${row.name}" paused` : `"${row.name}" resumed`, "emerald");
      reload();
    } catch (e) {
      pushToast(e.message || "Could not change the workflow", "red");
    }
  };

  const runWorkflow = async (id, inputs) => {
    setStarting(true);
    try {
      const res = await api.runWorkflow(id, inputs);
      if (res?.approvalRequired) {
        pushToast(
          "Complex workflow — an admin must approve this run",
          "amber",
        );
      } else {
        pushToast("Workflow run started", "cyan");
      }
      setPrompt(null);
      reload();
    } catch (e) {
      pushToast(e.message || "Could not run workflow", "red");
    } finally {
      setStarting(false);
    }
  };

  /**
   * Ask the workflow what it needs before triggering it. A provider-authored
   * workflow declares its own input form, so the console cannot know whether
   * to show a dialog until it has asked — and asking is cheap next to running
   * the wrong thing with an empty form.
   */
  const startRun = async (row) => {
    setAsking(row.id);
    try {
      const fields = await api.workflowInputs(row.id);
      if (Array.isArray(fields) && fields.length > 0) {
        setPrompt({ row, fields });
      } else {
        await runWorkflow(row.id);
      }
    } catch (e) {
      pushToast(e.message || "Could not read this workflow's inputs", "red");
    } finally {
      setAsking(null);
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Workflows"
        subtitle="Automations your provider has rolled out to this workspace"
      />
      <Toolbar
        placeholder="Search workflows…"
        right={<Chip>{rows.length} workflows</Chip>}
      />
      <Table
        loading={loading}
        error={error}
        onRetry={reload}
        empty="No workflows yet. Your provider rolls these out — talk to them about what you need automated."
        columns={[
          {
            key: "name",
            label: "Workflow",
            render: (r) => (
              <div>
                <span className="inline-flex items-center gap-2">
                  <span className="font-medium text-slate-900">{r.name}</span>
                  {r.providerManaged && (
                    <span
                      title="Designed and maintained by your provider"
                      className="inline-flex items-center gap-1 rounded-full border border-violet-400/30 bg-violet-400/10 px-2 py-0.5 text-[10px] font-medium text-violet-600"
                    >
                      <Icon name="shield" size={10} /> managed
                    </span>
                  )}
                  {r.requiresApproval && (
                    <span
                      title="Complex workflow — non-admin runs need approval"
                      className="inline-flex items-center gap-1 rounded-full border border-amber-400/30 bg-amber-400/10 px-2 py-0.5 text-[10px] font-medium text-amber-600"
                    >
                      <Icon name="lock" size={10} /> approval
                    </span>
                  )}
                </span>
                <p className="text-[11px] text-slate-500">
                  {r.category || "Uncategorized"}
                  {r.template ? " · template" : ""} · {r.steps || 0} steps
                </p>
              </div>
            ),
          },
          {
            key: "state",
            label: "State",
            render: (r) => <StatusBadge status={stateBadge(r.state)} />,
          },
          {
            key: "validation",
            label: "Validation",
            render: (r) =>
              r.validation === "issues" ? (
                <span className="rounded-full border border-amber-400/30 bg-amber-400/10 px-2.5 py-0.5 text-xs font-medium text-amber-600">
                  Issues
                </span>
              ) : (
                <span className="rounded-full border border-emerald-400/30 bg-emerald-400/10 px-2.5 py-0.5 text-xs font-medium text-emerald-600">
                  Valid
                </span>
              ),
          },
          {
            key: "successRate",
            label: "Success rate",
            render: (r) => <SuccessBar value={r.successRate} />,
          },
          {
            key: "lastRunAt",
            label: "Last run",
            render: (r) => (
              <span className="text-slate-500">
                {r.lastRunAt ? fmtDate(r.lastRunAt) : "Never"}
              </span>
            ),
          },
          {
            key: "act",
            label: "",
            // Run and pause. Editing and deleting a provider-managed workflow
            // are the provider's, so they are not offered here at all rather
            // than offered and refused.
            render: (r) =>
              canRun ? (
                <div
                  className="flex items-center justify-end gap-2"
                  onClick={(e) => e.stopPropagation()}
                >
                  <SmallButton
                    icon="play"
                    variant="primary"
                    disabled={!r.active || asking === r.id}
                    title={r.active ? undefined : "Resume this workflow to run it"}
                    onClick={() => startRun(r)}
                  >
                    {asking === r.id ? "Checking…" : "Run"}
                  </SmallButton>
                  <SmallButton
                    icon={r.active ? "stop" : "play"}
                    onClick={() => togglePaused(r)}
                  >
                    {r.active ? "Pause" : "Resume"}
                  </SmallButton>
                </div>
              ) : null,
          },
        ]}
        rows={rows}
      />

      {prompt && (
        <RunInputsDialog
          title={prompt.row.name}
          fields={prompt.fields}
          busy={starting}
          onCancel={() => setPrompt(null)}
          onRun={(inputs) => runWorkflow(prompt.row.id, inputs)}
        />
      )}
    </div>
  );
}
