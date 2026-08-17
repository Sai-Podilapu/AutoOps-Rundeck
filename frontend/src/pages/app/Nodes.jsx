import React, { useState } from "react";
import { useParams } from "react-router-dom";
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
import { fmtDate } from "../../lib/format";
import { api } from "../../lib/api";

const nodeBadge = (s) => {
  const v = String(s || "").toLowerCase();
  if (v === "online") return "active";
  if (v === "offline") return "offline";
  return v || "queued";
};

export default function Nodes() {
  const { pid } = useParams();
  const { can, pushToast } = useStore();
  const { rows, loading, error, reload, create } = useCollection("nodes", pid);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [formError, setFormError] = useState(null);
  const [editTarget, setEditTarget] = useState(null);
  const [deleteTarget, setDeleteTarget] = useState(null);
  const canWrite = can("deploy");

  const submit = async (values) => {
    setBusy(true);
    setFormError(null);
    try {
      if (editTarget) {
        await api.update("nodes", editTarget.id, values);
        pushToast("Node updated", "emerald");
        reload();
      } else {
        await create(values);
        pushToast("Node added", "emerald");
      }
      setOpen(false);
      setEditTarget(null);
    } catch (e) {
      setFormError(e.message || "Could not save node");
    } finally {
      setBusy(false);
    }
  };

  const doDelete = async () => {
    if (!deleteTarget) return;
    setBusy(true);
    try {
      await api.remove("nodes", deleteTarget.id);
      pushToast("Node deleted", "emerald");
      reload();
    } catch (e) {
      pushToast(e.message || "Failed to delete node", "red");
    } finally {
      setBusy(false);
      setDeleteTarget(null);
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Nodes"
        subtitle="Execution targets and runners for this project"
        actions={
          canWrite ? (
            <SmallButton
              icon="plus"
              variant="primary"
              onClick={() => {
                setEditTarget(null);
                setOpen(true);
              }}
            >
              Add Node
            </SmallButton>
          ) : null
        }
      />
      <Toolbar
        placeholder="Search nodes…"
        right={<Chip>{rows.length} nodes</Chip>}
      />
      <Table
        loading={loading}
        error={error}
        onRetry={reload}
        onRowClick={
          canWrite
            ? (r) => {
                setEditTarget(r);
                setOpen(true);
              }
            : undefined
        }
        empty="No nodes yet. Add an execution target to get started."
        columns={[
          {
            key: "name",
            label: "Node",
            render: (r) => (
              <span className="font-medium text-slate-900">{r.name}</span>
            ),
          },
          {
            key: "type",
            label: "Type",
            render: (r) => (
              <span className="font-mono text-xs text-slate-500">
                {r.type || "runner"}
              </span>
            ),
          },
          {
            key: "region",
            label: "Region",
            render: (r) => (
              <span className="text-slate-500">{r.region || "—"}</span>
            ),
          },
          {
            key: "createdAt",
            label: "Added",
            render: (r) => (
              <span className="text-slate-500">{fmtDate(r.createdAt)}</span>
            ),
          },
          {
            key: "status",
            label: "Status",
            render: (r) => <StatusBadge status={nodeBadge(r.status)} />,
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
                    icon="pencil"
                    onClick={() => {
                      setEditTarget(r);
                      setOpen(true);
                    }}
                  >
                    Edit
                  </SmallButton>
                  <button
                    onClick={() => setDeleteTarget(r)}
                    aria-label="Delete Node"
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
        title={editTarget ? "Edit node" : "Add node"}
        busy={busy}
        error={formError}
        onClose={() => {
          setOpen(false);
          setEditTarget(null);
        }}
        onSubmit={submit}
        submitLabel={editTarget ? "Save Changes" : "Add node"}
        fields={[
          {
            name: "name",
            label: "Node name",
            placeholder: "prod-runner-01",
            required: true,
            autoFocus: true,
            defaultValue: editTarget?.name,
          },
          {
            name: "type",
            label: "Type",
            type: "select",
            defaultValue: editTarget?.type || "runner",
            options: [
              { value: "runner", label: "Runner" },
              { value: "container", label: "Container" },
              { value: "vm", label: "Virtual machine" },
              { value: "serverless", label: "Serverless" },
            ],
          },
          {
            name: "region",
            label: "Region",
            placeholder: "us-east-1",
            defaultValue: editTarget?.region,
          },
        ]}
      />
      <ConfirmModal
        open={!!deleteTarget}
        title="Delete Node"
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
