/**
 * The list of Dify-backed workflows for a project — the way into the Dify
 * designer.
 *
 * Kept separate from Workflows.jsx because the two are different things: that
 * page lists workflows the AutoOps engine runs, this one lists Dify apps. A
 * single list mixing both would have to hide half its columns depending on the
 * row, and "Run" would mean two different code paths.
 */

import React, { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { PageHeader, Toolbar, Table, SmallButton, Chip } from "../../components/app/appui";
import { useStore } from "../../store/store";
import { fmtDate } from "../../lib/format";
import { difyApi } from "../../lib/dify/difyApi";

export default function DifyApps() {
  const { pid } = useParams();
  const navigate = useNavigate();
  const { can, pushToast } = useStore();
  const canWrite = can("editWorkflow");

  const [rows, setRows] = useState(null);
  const [q, setQ] = useState("");
  const [creating, setCreating] = useState(false);

  const load = () =>
    difyApi
      .listApps()
      .then((r) => setRows(Array.isArray(r) ? r : []))
      .catch((e) => {
        pushToast(e.message || "Could not load Dify workflows", "red");
        setRows([]);
      });

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const create = async () => {
    setCreating(true);
    try {
      const app = await difyApi.createApp({ name: "Untitled workflow", mode: "workflow" });
      navigate(`/app/projects/${pid}/dify/${app.id}`);
    } catch (e) {
      pushToast(e.message || "Could not create the workflow", "red");
    } finally {
      setCreating(false);
    }
  };

  const filtered = (rows || []).filter(
    (r) => !q || String(r.name || "").toLowerCase().includes(q.toLowerCase()),
  );

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="AI Workflows"
        subtitle="AI workflows your provider has rolled out to this project"

      />

      <Toolbar
        placeholder="Search AI workflows…"
        value={q}
        onChange={(e) => setQ(e.target.value)}
      />

      <Table
        loading={rows === null}
        columns={[
          {
            key: "name",
            label: "Name",
            render: (app) => (
              <Link
                to={`/app/projects/${pid}/dify/${app.id}`}
                className="font-semibold text-slate-900 transition hover:text-blue-600"
              >
                {app.name}
              </Link>
            ),
          },
          {
            key: "mode",
            label: "Mode",
            render: (app) => <Chip>{app.mode === "chat" ? "Chatflow" : "Workflow"}</Chip>,
          },
          {
            key: "published",
            label: "Status",
            render: (app) => (
              <span
                className={`rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide ${
                  app.published ? "bg-emerald-50 text-emerald-700" : "bg-slate-100 text-slate-500"
                }`}
              >
                {app.published ? "Published" : "Draft"}
              </span>
            ),
          },
          {
            key: "updated_at",
            label: "Updated",
            render: (app) => (app.updated_at ? fmtDate(app.updated_at) : "—"),
          },
          {
            key: "actions",
            label: "",
            render: (app) => (
              <SmallButton
                icon="pencil"
                onClick={() => navigate(`/app/projects/${pid}/dify/${app.id}`)}
              >
                Open
              </SmallButton>
            ),
          },
        ]}
        rows={filtered}
        empty="No AI workflows yet."
      />
    </div>
  );
}
