import React, { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import {
  PageHeader,
  Toolbar,
  Table,
  StatusBadge,
  SmallButton,
  Chip,
  ConfirmModal,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import FormModal from "../../components/app/FormModal";
import { useCollection } from "../../lib/useCollection";
import { useStore } from "../../store/store";
import { fmtDate, badgeStatus } from "../../lib/format";
import { api } from "../../lib/api";
import { base } from "../../lib/base";

export default function Jobs() {
  const { pid } = useParams();
  const navigate = useNavigate();
  const { can, pushToast } = useStore();
  const { rows, loading, error, reload, create } = useCollection("jobs", pid);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState(null);
  const [formError, setFormError] = useState(null);
  const canWrite = can("runWorkflow");

  const doDelete = async () => {
    if (!deleteTarget) return;
    setBusy(true);
    try {
      await api.remove("jobs", deleteTarget.id);
      pushToast("Job deleted", "emerald");
      reload();
    } catch (e) {
      pushToast(e.message || "Failed to delete job", "red");
    } finally {
      setBusy(false);
      setDeleteTarget(null);
    }
  };

  const submit = async (values) => {
    setBusy(true);
    setFormError(null);
    try {
      await create(values);
      setOpen(false);
      pushToast("Job created", "emerald");
    } catch (e) {
      setFormError(e.message || "Could not create job");
    } finally {
      setBusy(false);
    }
  };

  const runJob = async (id) => {
    try {
      const res = await api.runJob(id);
      if (res?.approvalRequired) {
        pushToast("Approval requested — an admin must approve this run", "amber");
      } else {
        pushToast("Job run started", "cyan");
      }
      reload();
    } catch (e) {
      pushToast(e.message || "Could not run job", "red");
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Jobs"
        subtitle="Reusable, parameterized automation jobs"
        actions={
          canWrite ? (
            <Link to={`${base()}/jobs/new`}>
              <SmallButton variant="primary">
                New Job
              </SmallButton>
            </Link>
          ) : null
        }
      />
      <Toolbar
        placeholder="Search jobs…"
        right={<Chip>{rows.length} jobs</Chip>}
      />
      <Table
        loading={loading}
        error={error}
        onRetry={reload}
        onRowClick={(r) => navigate(`${base()}/jobs/${r.id}`)}
        empty="No jobs yet. Create one to get started."
        columns={[
          {
            key: "name",
            label: "Job",
            render: (r) => (
              <span className="inline-flex items-center gap-2">
                <Link
                  to={`${base()}/jobs/${r.id}`}
                  className="font-medium text-slate-900 hover:text-slate-900"
                >
                  {r.name}
                </Link>
                {r.requiresApproval && (
                  <span
                    title="Runs need admin approval"
                    className="inline-flex items-center gap-1 rounded-full border border-amber-400/30 bg-amber-400/10 px-2 py-0.5 text-[10px] font-medium text-amber-600"
                  >
                    <Icon name="lock" size={10} /> approval
                  </span>
                )}
              </span>
            ),
          },
          {
            key: "schedule",
            label: "Schedule",
            render: (r) => (
              <span className="font-mono text-xs text-slate-500">
                {r.schedule || "—"}
              </span>
            ),
          },
          {
            key: "lastRunAt",
            label: "Last run",
            render: (r) => (
              <span className="text-slate-500">{fmtDate(r.lastRunAt)}</span>
            ),
          },
          {
            key: "status",
            label: "Status",
            render: (r) => <StatusBadge status={badgeStatus(r.status)} />,
          },
          {
            key: "act",
            label: "",
            render: (r) =>
              canWrite ? (
                <div
                  className="flex items-center justify-end gap-2"
                  onClick={(e) => e.stopPropagation()}
                >
                  <SmallButton
                    icon="play"
                    variant="primary"
                    onClick={() => runJob(r.id)}
                  >
                    Run
                  </SmallButton>
                  <SmallButton
                    icon="pencil"
                    onClick={() => navigate(`${base()}/jobs/${r.id}/edit`)}
                  >
                    Edit
                  </SmallButton>
                  <button
                    onClick={() => setDeleteTarget(r)}
                    aria-label="Delete Job"
                    className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3.5 py-2 text-sm font-semibold text-slate-900 transition duration-300 hover:border-red-500 hover:bg-red-500 hover:text-white"
                  >
                    <Icon name="trash" size={16} />
                    Delete
                  </button>
                </div>
              ) : null,
          },
        ]}
        rows={rows}
      />

      <FormModal
        open={open}
        title="New job"
        busy={busy}
        error={formError}
        onClose={() => setOpen(false)}
        onSubmit={submit}
        submitLabel="Create job"
        fields={[
          {
            name: "name",
            label: "Job name",
            placeholder: "Nightly backup",
            required: true,
            autoFocus: true,
          },
          {
            name: "schedule",
            label: "Schedule (cron, optional)",
            placeholder: "0 2 * * *",
          },
        ]}
      />
      <ConfirmModal
        open={!!deleteTarget}
        title="Delete Job"
        message={`Are you sure you want to permanently delete "${deleteTarget?.name}"?`}
        confirmLabel="Delete"
        tone="danger"
        onClose={() => setDeleteTarget(null)}
        onConfirm={doDelete}
      />
    </div>
  );
}
