import React, { useState, useEffect } from "react";
import { useParams } from "react-router-dom";
import {
  PageHeader,
  Toolbar,
  Table,
  StatusBadge,
  SmallButton,
  ConfirmModal,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import FormModal from "../../components/app/FormModal";
import { useStore } from "../../store/store";
import { api } from "../../lib/api";

export default function Webhooks() {
  const { pid } = useParams();
  const { pushToast } = useStore();
  const [webhooks, setWebhooks] = useState([]);
  const [jobs, setJobs] = useState([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [formError, setFormError] = useState(null);
  const [editTarget, setEditTarget] = useState(null);
  const [deleteTarget, setDeleteTarget] = useState(null);

  const load = () => {
    setLoading(true);
    Promise.all([api.list("webhooks"), api.list("jobs", pid).catch(() => [])])
      .then(([rows, jobRows]) => {
        // Webhooks are tenant-wide; this page scopes to the open project.
        setWebhooks(
          (Array.isArray(rows) ? rows : []).filter(
            (w) => String(w.projectId) === String(pid),
          ),
        );
        setJobs(Array.isArray(jobRows) ? jobRows : []);
        setLoading(false);
      })
      .catch(() => setLoading(false));
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pid]);

  const submit = async (values) => {
    setBusy(true);
    setFormError(null);
    try {
      const body = {
        name: values.name,
        targetType: "JOB",
        targetId: Number(values.jobId),
      };
      if (editTarget) {
        await api.update("webhooks", editTarget.id, body);
        pushToast("Webhook updated", "emerald");
      } else {
        const created = await api.create("webhooks", body);
        pushToast(`Webhook created — POST ${created.url}`, "emerald");
      }
      setOpen(false);
      setEditTarget(null);
      load();
    } catch (e) {
      setFormError(e.message || "Could not save webhook");
    } finally {
      setBusy(false);
    }
  };

  const doDelete = async () => {
    if (!deleteTarget) return;
    setBusy(true);
    try {
      await api.remove("webhooks", deleteTarget.id);
      pushToast("Webhook deleted", "emerald");
      load();
    } catch (e) {
      pushToast(e.message || "Failed to delete webhook", "red");
    } finally {
      setBusy(false);
      setDeleteTarget(null);
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Webhooks"
        subtitle="Inbound trigger URLs — POST to the endpoint to start the bound job"
        actions={
          <SmallButton icon="plus" variant="primary" onClick={() => {
            setEditTarget(null);
            setOpen(true);
          }}>
            New webhook
          </SmallButton>
        }
      />
      <Toolbar placeholder="Search webhooks…" />
      <Table
        columns={[
          {
            key: "name",
            label: "Name",
            render: (r) => (
              <span className="font-medium text-slate-900">{r.name}</span>
            ),
          },
          {
            key: "url",
            label: "Endpoint",
            render: (r) => (
              <span className="font-mono text-xs text-slate-500">{r.url}</span>
            ),
          },
          {
            key: "events",
            label: "Triggers",
            render: (r) => <span className="text-slate-600">{r.events}</span>,
          },
          {
            key: "last",
            label: "Last fired",
            render: (r) => <span className="text-slate-500">{r.last}</span>,
          },
          {
            key: "status",
            label: "Status",
            render: (r) => <StatusBadge status={r.status} />,
          },
          {
            key: "act",
            label: "",
            render: (r) => (
              <div className="flex items-center justify-end gap-3">
                <button
                  onClick={() => {
                    setEditTarget(r);
                    setOpen(true);
                  }}
                  className="text-slate-400 hover:text-slate-900"
                  aria-label="Edit Webhook"
                >
                  <Icon name="pencil" size={16} />
                </button>
                <button
                  onClick={() => setDeleteTarget(r)}
                  className="text-slate-400 hover:text-red-500"
                  aria-label="Delete Webhook"
                >
                  <Icon name="trash" size={16} />
                </button>
              </div>
            ),
          },
        ]}
        rows={webhooks}
      />
      <FormModal
        open={open}
        title={editTarget ? "Edit webhook" : "New webhook"}
        busy={busy}
        error={formError}
        onClose={() => {
          setOpen(false);
          setEditTarget(null);
        }}
        onSubmit={submit}
        submitLabel={editTarget ? "Save Changes" : "Create webhook"}
        fields={[
          {
            name: "name",
            label: "Webhook Name",
            placeholder: "GitHub PR Hook",
            required: true,
            autoFocus: true,
            defaultValue: editTarget?.name,
          },
          {
            name: "jobId",
            label: "Job to run when the webhook fires",
            type: "select",
            required: true,
            defaultValue: editTarget ? String(editTarget.targetId) : undefined,
            options: jobs.map((j) => ({ value: String(j.id), label: j.name })),
          },
        ]}
      />
      <ConfirmModal
        open={!!deleteTarget}
        title="Delete Webhook"
        message={`Are you sure you want to permanently delete "${deleteTarget?.name}"?`}
        confirmLabel="Delete"
        tone="danger"
        busy={busy}
        onClose={() => setDeleteTarget(null)}
        onConfirm={doDelete}
      />
    </div>
  );
}
