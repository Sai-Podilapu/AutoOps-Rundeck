import React, { useState, useEffect } from "react";
import { Link, useParams } from "react-router-dom";
import {
  PageHeader,
  Card,
  Table,
  StatusBadge,
  SmallButton,
  Chip,
  Pagination,
} from "../../components/app/appui";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";
import { fmtDate } from "../../lib/format";
import { base } from "../../lib/base";

const timeAgo = (value) => {
  if (!value) return "—";
  const ms = Date.now() - new Date(value).getTime();
  if (isNaN(ms) || ms < 0) return "—";
  const mins = Math.floor(ms / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
};

export default function Approvals() {
  const { pid } = useParams();
  const { can, pushToast } = useStore();
  const canApprove = can("approve");
  const [approvals, setApprovals] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [busyId, setBusyId] = useState(null);
  const [page, setPage] = useState(1);
  const [settings, setSettings] = useState(null);
  const [threshold, setThreshold] = useState("");
  const [riskyText, setRiskyText] = useState("");
  const [savingRules, setSavingRules] = useState(false);
  const pageSize = 10;

  const load = () => {
    setLoading(true);
    setError(null);
    Promise.all([
      api.list("approvals", pid),
      api.getApprovalSettings().catch(() => null),
    ])
      .then(([rows, s]) => {
        setApprovals(Array.isArray(rows) ? rows : []);
        if (s) {
          setSettings(s);
          setThreshold(String(s.complexNodeThreshold));
          setRiskyText((s.riskyTypes || []).join(", "));
        }
        setLoading(false);
      })
      .catch((e) => {
        setError(e.message || "Could not load approvals");
        setLoading(false);
      });
  };

  const parseRisky = (text) =>
    text
      .split(",")
      .map((t) => t.trim().toLowerCase())
      .filter(Boolean);

  const riskyChanged =
    settings &&
    parseRisky(riskyText).join(",") !== (settings.riskyTypes || []).join(",");
  const thresholdChanged =
    settings && threshold.trim() !== String(settings.complexNodeThreshold);

  const saveRules = async () => {
    const value = Number(threshold);
    if (thresholdChanged && (!Number.isInteger(value) || value < 1)) {
      pushToast("Threshold must be a whole number of 1 or more", "red");
      return;
    }
    setSavingRules(true);
    try {
      // Only send what changed, so an untouched knob keeps its default.
      const s = await api.updateApprovalSettings({
        threshold: thresholdChanged ? value : undefined,
        riskyTypes: riskyChanged ? parseRisky(riskyText) : undefined,
      });
      setSettings(s);
      setThreshold(String(s.complexNodeThreshold));
      setRiskyText((s.riskyTypes || []).join(", "));
      pushToast("Approval rules updated", "emerald");
    } catch (e) {
      pushToast(e.message || "Could not save approval rules", "red");
    } finally {
      setSavingRules(false);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pid]);

  const decide = async (row, action) => {
    setBusyId(row.id);
    try {
      if (action === "approve") {
        await api.approveApproval(row.id);
        pushToast(`Approved — "${row.target}" is running`, "emerald");
      } else {
        await api.rejectApproval(row.id);
        pushToast(`Rejected "${row.target}"`, "red");
      }
      load();
    } catch (e) {
      pushToast(e.message || `Could not ${action}`, "red");
    } finally {
      setBusyId(null);
    }
  };

  const pending = approvals.filter((a) => a.status === "pending").length;
  const paginated = approvals.slice((page - 1) * pageSize, page * pageSize);

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Approvals"
        subtitle={
          canApprove
            ? "Run requests for approval-gated jobs — approving starts the run"
            : "Your run requests for approval-gated jobs, awaiting an admin"
        }
        actions={<Chip>{pending} pending</Chip>}
      />

      {settings && (
        <Card className="mb-5 p-4">
          <p className="text-sm font-medium text-slate-900">
            Workflow approval rules
          </p>
          <p className="mt-0.5 text-xs text-slate-500">
            Workflows with{" "}
            <span className="font-semibold text-slate-900">
              {settings.complexNodeThreshold}+
            </span>{" "}
            nodes need admin approval
            {settings.complexNodeThreshold !== settings.platformDefault
              ? ` (default ${settings.platformDefault})`
              : ""}
            .{" "}
            {(settings.riskyTypes || []).length > 0 ? (
              <>
                Node types that always need approval:{" "}
                <span className="font-medium text-slate-700">
                  {(settings.riskyTypes || []).join(", ")}
                </span>
                {settings.riskyTypesCustomized
                  ? " (customized)"
                  : " (platform default)"}
                .
              </>
            ) : (
              "Risky-type gating is disabled — only the node count applies."
            )}{" "}
            Jobs are gated by their own per-job toggle.
          </p>
          {canApprove && (
            <div className="mt-3 flex flex-wrap items-end gap-3">
              <label className="text-xs font-medium text-slate-600">
                Node threshold
                <input
                  type="number"
                  min={1}
                  max={500}
                  value={threshold}
                  onChange={(e) => setThreshold(e.target.value)}
                  className="mt-1 block w-24 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-900 outline-none focus:border-slate-300"
                />
              </label>
              <label className="min-w-64 flex-1 text-xs font-medium text-slate-600">
                Always-approve node types (comma-separated; empty = disabled)
                <input
                  value={riskyText}
                  onChange={(e) => setRiskyText(e.target.value)}
                  placeholder="terraform, kubernetes, ssh…"
                  className="mt-1 block w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 font-mono text-sm text-slate-900 outline-none focus:border-slate-300"
                />
              </label>
              <SmallButton
                variant="primary"
                disabled={savingRules || (!thresholdChanged && !riskyChanged)}
                onClick={saveRules}
              >
                Save
              </SmallButton>
            </div>
          )}
        </Card>
      )}

      <Table
        loading={loading}
        error={error}
        onRetry={load}
        empty="No approval requests yet. Jobs with “Require admin approval” enabled will queue here when an operator runs them."
        columns={[
          {
            key: "target",
            label: "Request",
            render: (r) => (
              <div>
                <Link
                  to={`${base()}/${r.targetType === "workflow" ? "workflows" : "jobs"}/${r.targetId}`}
                  className="font-medium text-slate-900 hover:underline"
                >
                  {r.target}
                </Link>
                <p className="text-[11px] text-slate-500">
                  {r.targetType === "workflow" ? "Workflow" : "Job"} · requested{" "}
                  {fmtDate(r.createdAt)}
                </p>
              </div>
            ),
          },
          {
            key: "requestedBy",
            label: "Requested by",
            render: (r) => (
              <span className="text-slate-500">{r.requestedBy}</span>
            ),
          },
          {
            key: "age",
            label: "Age",
            render: (r) => (
              <span className="text-slate-500">{timeAgo(r.createdAt)}</span>
            ),
          },
          {
            key: "status",
            label: "Status",
            render: (r) => <StatusBadge status={r.status} />,
          },
          {
            key: "act",
            label: "",
            render: (r) =>
              r.status === "pending" ? (
                canApprove ? (
                  <div className="flex items-center justify-end gap-2">
                    <SmallButton
                      icon="check"
                      variant="primary"
                      disabled={busyId === r.id}
                      onClick={() => decide(r, "approve")}
                    >
                      Approve
                    </SmallButton>
                    <SmallButton
                      disabled={busyId === r.id}
                      onClick={() => decide(r, "reject")}
                    >
                      Reject
                    </SmallButton>
                  </div>
                ) : (
                  <span className="text-xs text-slate-500">
                    Waiting for an admin
                  </span>
                )
              ) : (
                <div className="text-right text-xs text-slate-500">
                  <p>
                    {r.status === "approved" ? "Approved" : "Rejected"} by{" "}
                    {r.decidedBy || "admin"} · {fmtDate(r.decidedAt)}
                  </p>
                  {r.runId && (
                    <Link
                      to={`${base()}/executions/${r.runId}`}
                      className="font-medium text-slate-900 hover:underline"
                    >
                      View run →
                    </Link>
                  )}
                </div>
              ),
          },
        ]}
        rows={paginated}
      />
      <div className="mt-4">
        <Pagination
          page={page}
          pageSize={pageSize}
          totalItems={approvals.length}
          onPageChange={setPage}
        />
      </div>
    </div>
  );
}