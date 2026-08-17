import React, { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import {
  PageHeader,
  Card,
  Table,
  SmallButton,
  StatusBadge,
} from "../../components/app/appui";
import { useStore } from "../../store/store";
import { api } from "../../lib/api";
import { planAllows, requiredPlan } from "../../lib/entitlements";
import UpgradeNotice from "../../components/app/UpgradeNotice";

const inputCls =
  "w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300";

const FRAMEWORKS = ["SOC 2", "ISO 27001", "HIPAA", "PCI-DSS", "GDPR"];

const CONTROL_STYLES = {
  PASS: "bg-emerald-400/10 text-emerald-600",
  WARN: "bg-amber-400/10 text-amber-600",
  FAIL: "bg-red-400/10 text-red-600",
  NOT_APPLICABLE: "bg-slate-400/10 text-slate-500",
};

const CONTROL_LABELS = {
  PASS: "Pass",
  WARN: "Warning",
  FAIL: "Fail",
  NOT_APPLICABLE: "N/A",
};

export default function ComplianceReports() {
  const { pid } = useParams();
  const { workspace, pushToast } = useStore();
  const plan = workspace?.plan;
  const allowed = planAllows(plan, "compliance");
  const b = `/app/projects/${pid}`;
  const [reports, setReports] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [framework, setFramework] = useState("SOC 2");
  const [detail, setDetail] = useState(null); // {report, content}

  useEffect(() => {
    if (!allowed) return;
    let alive = true;
    api
      .listComplianceReports(pid)
      .then((rows) => alive && setReports(rows))
      .catch(() => alive && pushToast("Could not load compliance reports", "red"))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, [pid, allowed]); // eslint-disable-line react-hooks/exhaustive-deps

  const generate = async () => {
    setBusy(true);
    try {
      const res = await api.generateComplianceReport(pid, framework);
      setReports((r) => [res.report, ...r]);
      setDetail(res);
      pushToast(
        res.report.compliant
          ? `${res.report.framework} report generated — compliant (${res.report.score}%)`
          : `${res.report.framework} report generated — ${res.report.failed} control(s) failing`,
        res.report.compliant ? "emerald" : "amber",
      );
    } catch (e) {
      pushToast(e.message || "Could not generate the report", "red");
    } finally {
      setBusy(false);
    }
  };

  const openDetail = async (row) => {
    if (detail?.report?.id === row.id) {
      setDetail(null);
      return;
    }
    try {
      setDetail(await api.getComplianceReport(row.id));
    } catch {
      pushToast("Could not load the report detail", "red");
    }
  };

  const download = async (row) => {
    try {
      await api.downloadComplianceReport(
        row.id,
        `${row.framework.toLowerCase().replace(/[^a-z0-9]+/g, "-")}-report-${row.id}.pdf`,
      );
    } catch (e) {
      pushToast(e.message || "Download failed", "red");
    }
  };

  if (!allowed)
    return (
      <div className="animate-fade-up">
        <Link
          to={`${b}/settings`}
          className="text-sm text-slate-500 hover:text-slate-900"
        >
          ← Project Settings
        </Link>
        <PageHeader
          title="Compliance Reports"
          subtitle="Generate audit-ready compliance reports"
        />
        <UpgradeNotice
          feature="Compliance reporting"
          plan={requiredPlan("compliance")}
        />
      </div>
    );

  return (
    <div className="animate-fade-up">
      <Link
        to={`${b}/settings`}
        className="text-sm text-slate-500 transition hover:text-slate-900"
      >
        ← Project Settings
      </Link>
      <PageHeader
        title="Compliance Reports"
        subtitle="Controls are evaluated against this project's real configuration and history"
      />

      <Card className="mb-6 max-w-2xl p-6">
        <h3 className="mb-4 text-sm font-semibold text-slate-900">
          Generate a report
        </h3>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-end">
          <div className="flex-1">
            <label className="mb-1.5 block text-xs font-medium text-slate-500">
              Framework
            </label>
            <select
              value={framework}
              onChange={(e) => setFramework(e.target.value)}
              className={inputCls}
            >
              {FRAMEWORKS.map((f) => (
                <option key={f}>{f}</option>
              ))}
            </select>
          </div>
          <SmallButton icon="doc" variant="primary" onClick={generate} disabled={busy}>
            {busy ? "Evaluating…" : "Generate Report"}
          </SmallButton>
        </div>
      </Card>

      <h3 className="mb-3 text-sm font-semibold text-slate-900">
        Report history
      </h3>
      <Table
        empty={loading ? "Loading reports…" : "No compliance reports generated yet."}
        onRowClick={openDetail}
        columns={[
          {
            key: "name",
            label: "Report",
            render: (r) => (
              <span className="font-medium text-slate-900">{r.name}</span>
            ),
          },
          {
            key: "framework",
            label: "Framework",
            render: (r) => (
              <span className="text-slate-500">{r.framework}</span>
            ),
          },
          {
            key: "score",
            label: "Score",
            render: (r) => (
              <span className="text-slate-500">
                {r.score}%{" "}
                <span className="text-xs text-slate-400">
                  ({r.passed}✓ {r.warnings}⚠ {r.failed}✗)
                </span>
              </span>
            ),
          },
          {
            key: "generated",
            label: "Generated",
            render: (r) => (
              <span className="text-slate-500">{r.generated}</span>
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
            render: (r) => (
              <span onClick={(e) => e.stopPropagation()}>
                <SmallButton icon="doc" onClick={() => download(r)}>
                  Download
                </SmallButton>
              </span>
            ),
          },
        ]}
        rows={reports}
      />

      {detail && (
        <Card className="mt-6 p-6">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <h3 className="text-sm font-semibold text-slate-900">
                {detail.report.framework} — control results
              </h3>
              <p className="text-xs text-slate-500">
                Generated {detail.report.generated} by {detail.report.generatedBy}
              </p>
            </div>
            <SmallButton onClick={() => setDetail(null)}>Close</SmallButton>
          </div>
          <div className="divide-y divide-slate-100">
            {(detail.content?.controls || []).map((c, i) => (
              <div key={i} className="flex gap-4 py-3">
                <span
                  className={`mt-0.5 h-fit shrink-0 rounded-full px-2 py-0.5 text-xs font-semibold ${
                    CONTROL_STYLES[c.status] || CONTROL_STYLES.NOT_APPLICABLE
                  }`}
                >
                  {CONTROL_LABELS[c.status] || c.status}
                </span>
                <div>
                  <div className="text-sm font-medium text-slate-900">
                    {c.ref} · {c.title}
                  </div>
                  <div className="text-xs text-slate-500">{c.requirement}</div>
                  <div className="mt-1 text-xs text-slate-600">{c.evidence}</div>
                </div>
              </div>
            ))}
          </div>
        </Card>
      )}
    </div>
  );
}