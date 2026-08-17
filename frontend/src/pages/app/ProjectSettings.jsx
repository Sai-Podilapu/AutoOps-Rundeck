import React, { useState } from "react";
import { Link, useParams, useNavigate } from "react-router-dom";
import {
  PageHeader,
  Card,
  Table,
  StatusBadge,
  SmallButton,
  Pagination,
  ConfirmModal,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import { useStore } from "../../store/store";

export default function ProjectSettings() {
  const { pid } = useParams();
  const navigate = useNavigate();
  const {
    projects,
    members,
    refreshMembers,
    updateProject,
    removeProject,
    pushToast,
  } = useStore();
  const [page, setPage] = useState(1);
  const pageSize = 5;

  const project = projects.find((p) => String(p.id) === String(pid));
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [busy, setBusy] = useState(false);
  const [deleteModal, setDeleteModal] = useState(false);

  React.useEffect(() => {
    refreshMembers();
  }, [refreshMembers]);

  // The store is empty on a hard refresh and fills in a tick later, but
  // useState's initial value only runs on mount — so seed the fields when the
  // row actually arrives. Keyed on the id (not the whole row) so a background
  // refresh can't overwrite what the user is typing.
  const seededFor = React.useRef(null);
  React.useEffect(() => {
    if (!project || seededFor.current === project.id) return;
    seededFor.current = project.id;
    setName(project.name || "");
    setDescription(project.description || "");
  }, [project]);

  const saveGeneral = async () => {
    if (busy) return;
    if (!name.trim()) {
      pushToast("Project name is required", "red");
      return;
    }
    setBusy(true);
    try {
      await updateProject(project.id, {
        name: name.trim(),
        description: description.trim(),
      });
      pushToast("Project updated successfully", "emerald");
    } catch (err) {
      pushToast(err.message || "Failed to update project", "red");
    } finally {
      setBusy(false);
    }
  };

  const paginatedMembers = members.slice(
    (page - 1) * pageSize,
    page * pageSize,
  );
  const b = `/app/projects/${pid}`;
  if (!project)
    return (
      <div className="animate-fade-up">
        <PageHeader
          title="Project not found"
          subtitle="This project isn’t available yet."
        />
        <Card className="p-10 text-center text-sm text-slate-500">
          Nothing here yet.{" "}
          <Link to="/app/projects" className="text-slate-900 hover:underline">
            Back to projects
          </Link>
        </Card>
      </div>
    );

  const hub = [
    {
      to: `${b}/scm`,
      label: "Setup SCM",
      desc: "Sync definitions with Git",
      icon: "doc",
    },
    {
      to: `${b}/access`,
      label: "Access Control",
      desc: "Roles & permissions",
      icon: "users",
    },
    // Plugin Manager is gone with the connectors screen it mirrored: it was a
    // read-only view of a list only Settings → Plugins could fill, and nothing
    // dispatched through a connector anyway. Alert Channels is the one place
    // for outbound integrations now.
    // Governance and Key Storage live in the sidebar (GOVERN) — no tile here.
  ];

  return (
    <div className="animate-fade-up">
      <Link
        to={b}
        className="text-sm text-slate-500 transition hover:text-slate-900"
      >
        ← {project.name}
      </Link>
      <PageHeader
        title="Project Settings"
        subtitle="Configure this project, its members and lifecycle"
      />

      <div className="mb-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {hub.map((h) => (
          <Link key={h.to} to={h.to} className="group">
            <Card className="flex h-full items-start gap-3 p-5 transition duration-300 hover:-translate-y-1 hover:border-blue-500 hover:bg-slate-50">
              <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-slate-100 text-slate-900">
                <Icon name={h.icon} size={20} />
              </span>
              <div>
                <p className="text-sm font-semibold text-slate-900">
                  {h.label}
                </p>
                <p className="mt-0.5 text-xs text-slate-500">{h.desc}</p>
              </div>
            </Card>
          </Link>
        ))}
      </div>

      <div className="grid gap-6 lg:grid-cols-2 items-stretch">
        <Card className="flex h-full flex-col p-6">
          <h3 className="mb-4 text-sm font-semibold text-slate-900">General</h3>
          <label className="mb-1.5 block text-xs font-medium text-slate-500">
            Project name
          </label>
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="mb-4 w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
          />
          <label className="mb-1.5 block text-xs font-medium text-slate-500">
            Description
          </label>
          <textarea
            rows={3}
            value={description}
            maxLength={255}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="What this project automates…"
            className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
          />
          <p className="mt-1.5 text-xs text-slate-500">
            Shown on the project card. {255 - description.length} characters
            left.
          </p>
          <div className="mt-auto flex justify-end border-t border-slate-200 pt-5">
            <SmallButton
              icon="check"
              variant="primary"
              onClick={saveGeneral}
              disabled={busy}
            >
              {busy ? "Saving…" : "Save changes"}
            </SmallButton>
          </div>
        </Card>
        <Card className="flex h-full flex-col p-6">
          <h3 className="mb-4 text-sm font-semibold text-slate-900">Members</h3>
          <div className="flex-1 overflow-hidden rounded-lg border border-slate-200">
            <Table
              cardClass="border-0 shadow-none !rounded-none"
              columns={[
                {
                  key: "name",
                  label: "Member",
                  render: (r) => (
                    <div>
                      <p className="font-medium text-slate-900">{r.name}</p>
                      <p className="text-xs text-slate-500">{r.email}</p>
                    </div>
                  ),
                },
                {
                  key: "role",
                  label: "Role",
                  render: (r) => (
                    <span className="text-sm text-slate-600">{r.role}</span>
                  ),
                },
                {
                  key: "status",
                  label: "Status",
                  render: (r) => <StatusBadge status={r.status} />,
                },
              ]}
              rows={paginatedMembers}
            />
          </div>
          <div className="mt-4">
            <Pagination
              page={page}
              pageSize={pageSize}
              totalItems={members.length}
              onPageChange={setPage}
            />
          </div>
        </Card>
      </div>

      <Card className="mt-6 border-red-400/20 bg-red-400/[0.03] p-6">
        <h3 className="text-sm font-semibold text-red-600">Danger zone</h3>
        <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
          <p className="text-sm text-slate-500">
            Archiving hides the project. Deleting permanently removes all its
            jobs, executions and assignments.
          </p>
          <div className="flex gap-2">
            <button className="rounded-lg border border-slate-200 px-3.5 py-2 text-sm font-semibold text-slate-900 transition hover:bg-slate-100">
              Archive
            </button>
            <button
              onClick={() => setDeleteModal(true)}
              className="rounded-lg border border-red-400/30 bg-red-400/10 px-3.5 py-2 text-sm font-semibold text-red-600 transition hover:bg-red-400/20"
            >
              Delete project
            </button>
          </div>
        </div>
      </Card>

      <ConfirmModal
        open={deleteModal}
        title="Delete Project"
        message={`Are you sure you want to permanently delete "${project.name}"? This action cannot be undone.`}
        confirmLabel="Delete"
        tone="danger"
        onClose={() => setDeleteModal(false)}
        onConfirm={async () => {
          try {
            setBusy(true);
            await removeProject(project.id);
            navigate("/app/projects");
            pushToast("Project deleted", "emerald");
          } catch (e) {
            pushToast(e.message || "Failed to delete", "red");
            setBusy(false);
            setDeleteModal(false);
          }
        }}
      />
    </div>
  );
}
