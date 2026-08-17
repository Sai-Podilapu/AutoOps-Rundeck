import { useState, useEffect } from "react";
import { Link, useParams } from "react-router-dom";
import {
  PageHeader,
  StatCard,
  Card,
  StatusBadge,
  CloudHealthBadge,
  Table,
  SmallButton,
  Pagination,
} from "../../components/app/appui";
import CloudLogo from "../../components/app/CloudLogo";
import ThroughputChart from "../../components/app/ThroughputChart";
import { platformById } from "../../data/saasData";
import { useStore } from "../../store/store";
import { api } from "../../lib/api";

export default function ProjectOverview() {
  const [page, setPage] = useState(1);
  const [executions, setExecutions] = useState([]);
  const [clouds, setClouds] = useState([]);
  const [loading, setLoading] = useState(true);
  const pageSize = 5;
  const { pid } = useParams();
  const { projects, workspace } = useStore();

  useEffect(() => {
    setLoading(true);
    Promise.all([
      api.list("executions", pid).catch(() => []),
      api.listCloudConnections().catch(() => []),
    ]).then(([execs, cls]) => {
      setLoading(false);
      setExecutions(Array.isArray(execs) ? execs : []);
      // Only what this project can actually deploy to: its own connections
      // plus the global ones.
      setClouds(
        (Array.isArray(cls) ? cls : []).filter(
          (c) => c.projectId == null || String(c.projectId) === String(pid),
        ),
      );
    });
  }, [pid]);

  const project = projects.find((p) => String(p.id) === String(pid));
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
  const b = `/app/projects/${project.id}`;

  const successCount = executions.filter((e) => e.status === "success").length;
  const successRate =
    executions.length > 0
      ? ((successCount / executions.length) * 100).toFixed(1) + "%"
      : "—";
  const kpis = [
    {
      label: "Executions",
      value: String(executions.length),
      icon: "play",
      tone: "cyan",
    },
    {
      label: "Success rate",
      value: successRate,
      icon: "shield",
      tone: "emerald",
    },
    {
      label: "Cloud integrations",
      value: String(clouds.length),
      icon: "cloud",
      tone: "violet",
    },
    {
      label: "Running now",
      value: String(executions.filter((e) => e.status === "running").length),
      icon: "clock",
      tone: "cyan",
    },
  ];
  const paginatedExecutions = executions.slice(
    (page - 1) * pageSize,
    page * pageSize,
  );

  return (
    <div className="animate-fade-up">
      <Link
        to="/app/projects"
        className="text-sm text-slate-500 transition hover:text-slate-900"
      >
        ← All projects
      </Link>
      <PageHeader
        title={project.name}
        subtitle={
          project.description ||
          `Project workspace · ${workspace?.plan || "Unknown"} plan`
        }
        actions={
          <>
            <Link to={`${b}/integrations`}>
              <SmallButton icon="cloud">Clouds</SmallButton>
            </Link>
            <Link to={`${b}/jobs`}>
              <SmallButton icon="plus" variant="primary">
                New Job
              </SmallButton>
            </Link>
          </>
        }
      />
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {kpis.map((k) => (
          <StatCard key={k.label} {...k} />
        ))}
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <ThroughputChart
          executions={executions}
          loading={loading}
          className="p-6 lg:col-span-2"
        />
        <Card className="p-6">
          <div className="mb-4 flex items-center justify-between">
            <h3 className="text-sm font-semibold text-slate-900">
              Cloud integrations
            </h3>
            <Link
              to={`${b}/integrations`}
              className="text-xs font-medium text-slate-900 hover:underline"
            >
              Manage →
            </Link>
          </div>
          {clouds.length ? (
            <div className="space-y-2">
              {clouds.map((c) => {
                const pf = platformById(c.platform);
                return (
                  <div
                    key={c.id}
                    className="flex items-center justify-between rounded-lg border border-slate-200 bg-slate-50 px-3 py-2.5"
                  >
                    <div className="flex items-center gap-2.5">
                      <span className="flex h-7 w-7 items-center justify-center rounded-md border border-slate-200 bg-white">
                        <CloudLogo platform={pf} size={16} />
                      </span>
                      <div>
                        <p className="text-sm text-slate-700">
                          {c.accountName || pf.name}
                        </p>
                        <p className="text-[11px] text-slate-500">
                          {[c.accountId, c.region]
                            .filter(Boolean)
                            .join(" · ") || "—"}
                        </p>
                      </div>
                    </div>
                    <CloudHealthBadge connection={c} />
                  </div>
                );
              })}
            </div>
          ) : (
            <div className="rounded-lg border border-dashed border-slate-200 px-4 py-8 text-center">
              <p className="text-sm text-slate-500">
                No cloud assigned to this project.
              </p>
              <Link
                to={`${b}/integrations`}
                className="mt-2 inline-block text-xs font-medium text-slate-900 hover:underline"
              >
                Assign a cloud →
              </Link>
            </div>
          )}
        </Card>
      </div>

      <div className="mt-6">
        <div className="mb-3 flex items-center justify-between">
          <h3 className="text-sm font-semibold text-slate-900">
            Recent executions
          </h3>
          <Link
            to={`${b}/executions`}
            className="text-xs font-medium text-slate-900 hover:underline"
          >
            View all →
          </Link>
        </div>
        <Table
          columns={[
            {
              key: "id",
              label: "#",
              render: (r) => (
                <span className="font-mono text-slate-500">{r.id}</span>
              ),
            },
            {
              key: "name",
              label: "Execution",
              render: (r) => (
                <Link
                  to={`${b}/executions/${r.id}`}
                  className="font-medium text-slate-900 hover:text-slate-900"
                >
                  {r.name}
                </Link>
              ),
            },
            { key: "workflow", label: "Script" },
            {
              key: "status",
              label: "Status",
              render: (r) => <StatusBadge status={r.status} />,
            },
            {
              key: "duration",
              label: "Duration",
              render: (r) => <span className="font-mono">{r.duration}</span>,
            },
            {
              key: "by",
              label: "By",
              render: (r) => <span className="text-slate-500">{r.by}</span>,
            },
          ]}
          rows={paginatedExecutions}
        />
        <div className="mt-4">
          <Pagination
            page={page}
            pageSize={pageSize}
            totalItems={executions.length}
            onPageChange={setPage}
          />
        </div>
      </div>
    </div>
  );
}
