import React, { useState, useEffect } from "react";
import {
  PageHeader,
  Toolbar,
  Table,
  SmallButton,
  Chip,
  Pagination,
  ConfirmModal,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import FormModal from "../../components/app/FormModal";
import { useStore } from "../../store/store";
import { api } from "../../lib/api";

export default function KeyStorage() {
  const { pushToast } = useStore();
  const [keys, setKeys] = useState([]);
  const [loading, setLoading] = useState(true);
  const [page, setPage] = useState(1);
  const pageSize = 10;
  
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [formError, setFormError] = useState(null);
  const [editTarget, setEditTarget] = useState(null);
  const [deleteTarget, setDeleteTarget] = useState(null);

  const load = () => {
    setLoading(true);
    api.list("secrets")
      .then((rows) => { setKeys(Array.isArray(rows) ? rows : []); setLoading(false); })
      .catch(() => setLoading(false));
  };

  useEffect(() => {
    load();
  }, []);

  const submit = async (values) => {
    setBusy(true);
    setFormError(null);
    try {
      if (editTarget) {
        await api.update("secrets", editTarget.id || encodeURIComponent(editTarget.path), values);
        pushToast("Secret updated", "emerald");
      } else {
        await api.create("secrets", values);
        pushToast("Secret added", "emerald");
      }
      setOpen(false);
      setEditTarget(null);
      load();
    } catch (e) {
      setFormError(e.message || "Could not save secret");
    } finally {
      setBusy(false);
    }
  };

  const doDelete = async () => {
    if (!deleteTarget) return;
    setBusy(true);
    try {
      await api.remove("secrets", deleteTarget.id || encodeURIComponent(deleteTarget.path));
      pushToast("Secret deleted", "emerald");
      load();
    } catch (e) {
      pushToast(e.message || "Failed to delete secret", "red");
    } finally {
      setBusy(false);
      setDeleteTarget(null);
    }
  };

  const paginatedKeys = keys.slice((page - 1) * pageSize, page * pageSize);

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Key Storage"
        subtitle="Per-tenant secrets, AES-256 encrypted at rest — values are write-only"
        actions={
          <SmallButton icon="plus" variant="primary" onClick={() => {
            setEditTarget(null);
            setOpen(true);
          }}>
            Add secret
          </SmallButton>
        }
      />
      <Toolbar placeholder="Search secrets…" />
      <Table
        columns={[
          {
            key: "path",
            label: "Path",
            render: (r) => (
              <span className="flex items-center gap-2 font-mono text-xs text-slate-700">
                <Icon name="lock" size={14} className="text-emerald-600" />
                {r.path}
              </span>
            ),
          },
          { key: "type", label: "Type", render: (r) => <Chip>{r.type}</Chip> },
          {
            key: "value",
            label: "Value",
            render: () => (
              <span className="font-mono text-slate-500">••••••••</span>
            ),
          },
          {
            key: "createdBy",
            label: "Created by",
            render: (r) => (
              <span className="text-slate-500">{r.createdBy || "—"}</span>
            ),
          },
          {
            key: "updated",
            label: "Updated",
            render: (r) => <span className="text-slate-500">{r.updated || "—"}</span>,
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
                  aria-label="Edit Secret"
                >
                  <Icon name="pencil" size={16} />
                </button>
                <button
                  onClick={() => setDeleteTarget(r)}
                  className="text-slate-400 hover:text-red-500"
                  aria-label="Delete Secret"
                >
                  <Icon name="trash" size={16} />
                </button>
              </div>
            ),
          },
        ]}
        rows={paginatedKeys}
      />
      <div className="mt-4">
        <Pagination
          page={page}
          pageSize={pageSize}
          totalItems={keys.length}
          onPageChange={setPage}
        />
      </div>

      <FormModal
        open={open}
        title={editTarget ? "Edit secret" : "Add secret"}
        busy={busy}
        error={formError}
        onClose={() => {
          setOpen(false);
          setEditTarget(null);
        }}
        onSubmit={submit}
        submitLabel={editTarget ? "Save Changes" : "Add secret"}
        fields={[
          {
            name: "path",
            label: "Secret Path (e.g. apps/production/api-key)",
            placeholder: "apps/production/api-key",
            required: true,
            autoFocus: true,
            defaultValue: editTarget?.path,
          },
          {
            name: "type",
            label: "Type",
            type: "select",
            defaultValue: editTarget?.type || "Opaque",
            options: [
              { value: "Opaque", label: "Opaque" },
              { value: "TLS", label: "TLS Certificate" },
              { value: "SSH", label: "SSH Key" },
            ],
          },
          {
            name: "value",
            label: editTarget ? "New value (blank keeps the current one)" : "Value",
            placeholder: "secret-value...",
            required: !editTarget,
          },
        ]}
      />
      <ConfirmModal
        open={!!deleteTarget}
        title="Delete Secret"
        message={`Are you sure you want to permanently delete "${deleteTarget?.path}"?`}
        confirmLabel="Delete"
        tone="danger"
        busy={busy}
        onClose={() => setDeleteTarget(null)}
        onConfirm={doDelete}
      />
    </div>
  );
}
