import React, { useState } from "react";
import { Link } from "react-router-dom";
import {
  PageHeader,
  Toolbar,
  Card,
  StatusBadge,
  SmallButton,
  Skeleton,
} from "../../components/app/appui";
import FormModal from "../../components/app/FormModal";
import Icon from "../../components/Icon";
import { useStore } from "../../store/store";
import { tiers } from "../../data/saasData";

export default function Projects() {
  const { projects, addProject, can, pushToast, booting, workspace } = useStore();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [query, setQuery] = useState("");

  const plan = tiers[workspace?.plan] || {};
  const used = projects.length;
  const limit = plan.projects;
  const atLimit = typeof limit === "number" && used >= limit;
  const canCreate = can("manageProject");

  const filtered = projects.filter((p) =>
    (p.name || "").toLowerCase().includes(query.toLowerCase()),
  );

  const create = async (values) => {
    setBusy(true);
    setError(null);
    try {
      await addProject(values);
      setOpen(false);
      pushToast("Project created", "emerald");
    } catch (e) {
      setError(e.message || "Could not create project");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Projects"
        subtitle="Each project is an isolated workspace with its own jobs, nodes, clouds and policies"
        actions={
          canCreate ? (
            <SmallButton
              icon="plus"
              variant="primary"
              onClick={() => setOpen(true)}
              disabled={atLimit}
            >
              New project
            </SmallButton>
          ) : null
        }
      />

      <Card className="mb-6 flex flex-wrap items-center justify-between gap-4 p-4">
        <div className="flex items-center gap-3">
          <span className="flex h-9 w-9 items-center justify-center rounded-lg bg-slate-100 text-slate-900">
            <Icon name="folder" size={18} />
          </span>
          <div>
            <p className="text-sm text-slate-600">
              <span className="font-semibold text-slate-900">{used}</span> of{" "}
              {typeof limit === "number" ? limit : "∞"} projects used ·{" "}
              <span className="text-slate-500">{workspace?.plan || "Unknown"} plan</span>
            </p>
            <div className="mt-1.5 h-2 w-48 overflow-hidden rounded-full bg-slate-200">
              <div
                className={`h-full rounded-full bg-gradient-to-r transition-all duration-500 ${
                  typeof limit === "number" && (used / limit) >= 0.9
                    ? "from-red-500 to-red-600"
                    : typeof limit === "number" && (used / limit) >= 0.75
                      ? "from-amber-400 to-amber-500"
                      : "from-emerald-400 to-emerald-500"
                }`}
                style={{
                  width:
                    typeof limit === "number"
                      ? `${Math.max(2, Math.min(100, (used / limit) * 100))}%`
                      : "30%",
                }}
              />
            </div>
          </div>
        </div>
        {atLimit && (
          <Link
            to="/pricing"
            className="rounded-lg border border-slate-300 bg-slate-100 px-3 py-1.5 text-xs font-medium text-slate-900 transition hover:bg-slate-100"
          >
            Upgrade for more projects
          </Link>
        )}
      </Card>

      <Toolbar
        placeholder="Search projects…"
        right={
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Filter…"
            className="hidden rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-900 outline-none focus:border-slate-300 sm:block"
          />
        }
      />

      {booting ? (
        <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {Array.from({ length: 3 }).map((_, i) => (
            <Card key={i} className="h-44 p-6">
              <Skeleton className="h-11 w-11 rounded-xl" />
              <Skeleton className="mt-4 h-5 w-2/3" />
              <Skeleton className="mt-3 h-4 w-1/3" />
            </Card>
          ))}
        </div>
      ) : filtered.length === 0 ? (
        <Card className="flex flex-col items-center justify-center gap-3 p-12 text-center">
          <span className="flex h-12 w-12 items-center justify-center rounded-xl bg-slate-100 text-slate-900">
            <Icon name="folder" size={24} />
          </span>
          <div>
            <p className="text-sm font-medium text-slate-900">
              No projects yet
            </p>
            <p className="mt-1 text-sm text-slate-500">
              Create your first project to start adding jobs, nodes and
              scripts.
            </p>
          </div>
          {canCreate && (
            <SmallButton
              icon="plus"
              variant="primary"
              onClick={() => setOpen(true)}
            >
              New project
            </SmallButton>
          )}
        </Card>
      ) : (
        <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {filtered.map((p) => (
            <Link key={p.id} to={`/app/projects/${p.id}`} className="group">
              <Card className="h-full p-6 transition duration-300 hover:-translate-y-1.5 hover:border-blue-500 hover:bg-slate-100">
                <div className="flex items-start justify-between">
                  <span className="flex h-11 w-11 items-center justify-center rounded-xl bg-gradient-to-br from-slate-200 to-slate-200 text-slate-900 transition group-hover:scale-110">
                    <Icon name="folder" size={22} />
                  </span>
                  <StatusBadge status={(p.status || "active").toLowerCase()} />
                </div>
                <h3 className="mt-4 text-lg font-semibold text-slate-900">
                  {p.name}
                </h3>
                {p.description ? (
                  <p className="mt-1 line-clamp-2 text-sm text-slate-500">
                    {p.description}
                  </p>
                ) : (
                  <p className="mt-1 text-sm text-slate-600">
                    {p.key ? `Key: ${p.key}` : "No description"}
                  </p>
                )}
                <p className="mt-5 flex items-center gap-1 text-xs font-medium text-slate-900 opacity-0 transition group-hover:opacity-100">
                  Open project <Icon name="chevron" size={12} />
                </p>
              </Card>
            </Link>
          ))}
        </div>
      )}

      <FormModal
        open={open}
        title="New project"
        description="Projects isolate jobs, nodes, scripts and clouds."
        busy={busy}
        error={error}
        onClose={() => setOpen(false)}
        onSubmit={create}
        submitLabel="Create project"
        fields={[
          {
            name: "name",
            label: "Project name",
            placeholder: "Production Ops",
            required: true,
            autoFocus: true,
          },
          {
            name: "key",
            label: "Key (optional)",
            placeholder: "PROD",
          },
          {
            name: "description",
            label: "Description (optional)",
            type: "textarea",
            placeholder: "What this project automates…",
          },
        ]}
      />
    </div>
  );
}
