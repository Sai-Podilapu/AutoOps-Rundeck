import React, { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import {
  PageHeader,
  Card,
  SmallButton,
  Chip,
  Skeleton,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";
import { planAllows, requiredPlan } from "../../lib/entitlements";
import UpgradeNotice from "../../components/app/UpgradeNotice";

const inputCls =
  "w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300";

export default function SetupScm() {
  const { pid } = useParams();
  const { workspace, can, pushToast } = useStore();
  const plan = workspace?.plan;
  const allowed = planAllows(plan, "scm");
  const canConfigure = can("manageProject");
  const b = `/app/projects/${pid}`;

  const [loading, setLoading] = useState(true);
  const [configured, setConfigured] = useState(false);
  const [hasToken, setHasToken] = useState(false);
  const [repoUrl, setRepoUrl] = useState("");
  const [savedRepoUrl, setSavedRepoUrl] = useState("");
  const [branch, setBranch] = useState("main");
  const [basePath, setBasePath] = useState("automation");
  const [username, setUsername] = useState("");
  const [token, setToken] = useState("");
  const [clearToken, setClearToken] = useState(false);
  const [strategy, setStrategy] = useState("OVERWRITE");
  const [saving, setSaving] = useState(false);
  const [syncing, setSyncing] = useState(null); // "export" | "import" | null
  const [result, setResult] = useState(null); // {kind, ...response}

  // A stored token was issued for the saved repo. Point the config at a
  // different one and the backend would silently reuse it (blank token = keep),
  // so the clone 401s. Treat it as gone and make the admin re-enter it.
  const repoChanged = configured && repoUrl.trim() !== savedRepoUrl;
  const storedTokenApplies = hasToken && !repoChanged && !clearToken;
  const tokenRequired = repoChanged && hasToken && !clearToken;

  useEffect(() => {
    if (!allowed) return;
    setLoading(true);
    api
      .getScmConfig(pid)
      .then((c) => {
        setConfigured(c.configured);
        if (c.configured) {
          setRepoUrl(c.repoUrl || "");
          setSavedRepoUrl(c.repoUrl || "");
          setBranch(c.branch || "main");
          setBasePath(c.basePath ?? "");
          setUsername(c.username || "");
          setHasToken(!!c.hasToken);
        }
      })
      .catch((e) =>
        pushToast(e.message || "Could not load SCM settings", "red"),
      )
      .finally(() => setLoading(false));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pid, allowed]);

  const saveConfig = async () => {
    if (!repoUrl.trim()) {
      pushToast("Repository URL is required", "red");
      return;
    }
    if (tokenRequired && !token.trim()) {
      pushToast(
        "The repository URL changed — enter the access token for the new repository",
        "red",
      );
      return;
    }
    setSaving(true);
    try {
      const c = await api.saveScmConfig(pid, {
        repoUrl: repoUrl.trim(),
        branch: branch.trim() || "main",
        basePath: basePath.trim(),
        username: username.trim() || null,
        token: clearToken ? null : token.trim() || null, // blank keeps the stored token
        clearToken, // explicit "this repo needs no credentials"
      });
      setConfigured(true);
      setHasToken(!!c.hasToken);
      setSavedRepoUrl(c.repoUrl || repoUrl.trim());
      setToken("");
      setClearToken(false);
      pushToast("Repository settings saved", "emerald");
    } catch (e) {
      pushToast(e.message || "Could not save settings", "red");
    } finally {
      setSaving(false);
    }
  };

  const runExport = async () => {
    setSyncing("export");
    setResult(null);
    try {
      const r = await api.scmExport(pid);
      setResult({ kind: "export", ...r });
      pushToast(
        r.pushed
          ? `Exported ${r.jobs} job(s) and ${r.workflows} workflow(s) to Git`
          : "Repository already up to date — nothing to commit",
        r.pushed ? "emerald" : "cyan",
      );
    } catch (e) {
      pushToast(e.message || "Export failed", "red");
    } finally {
      setSyncing(null);
    }
  };

  const runImport = async () => {
    setSyncing("import");
    setResult(null);
    try {
      const r = await api.scmImport(pid, strategy);
      setResult({ kind: "import", ...r });
      pushToast(
        `Import done: ${r.created} created, ${r.updated} updated, ${r.skipped} skipped` +
          (r.errors?.length ? `, ${r.errors.length} error(s)` : ""),
        r.errors?.length ? "amber" : "emerald",
      );
    } catch (e) {
      pushToast(e.message || "Import failed", "red");
    } finally {
      setSyncing(null);
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
          title="Setup SCM"
          subtitle="Version-control your job definitions"
        />
        <UpgradeNotice feature="SCM sync" plan={requiredPlan("scm")} />
      </div>
    );

  if (loading)
    return (
      <div className="animate-fade-up">
        <Skeleton className="h-4 w-24" />
        <Skeleton className="mt-4 h-8 w-72" />
        <div className="mt-6 grid max-w-6xl gap-6 lg:grid-cols-2">
          <Card className="h-96 p-6">
            <Skeleton className="h-5 w-40" />
          </Card>
          <Card className="h-96 p-6">
            <Skeleton className="h-5 w-24" />
          </Card>
        </div>
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
        title="Setup SCM"
        subtitle="Sync this project's job and workflow definitions with a Git repository"
        actions={
          configured ? (
            <Chip>
              {branch} · {basePath || "repo root"}
            </Chip>
          ) : null
        }
      />

      <div className="grid max-w-6xl gap-6 lg:grid-cols-2">
        <Card className="flex flex-col p-6">
          <h3 className="mb-1 text-sm font-semibold text-slate-900">
            Repository
          </h3>
          <p className="mb-5 text-xs leading-relaxed text-slate-500">
            Definitions are written as one JSON file per job/workflow under{" "}
            <span className="font-mono">{basePath || "the repo root"}</span>.
            Use an HTTPS URL with a personal access token
            {canConfigure ? "" : " (only admins can change these settings)"}.
          </p>
          <label className="mb-1.5 block text-xs font-medium text-slate-500">
            Repository URL
          </label>
          <input
            value={repoUrl}
            onChange={(e) => setRepoUrl(e.target.value)}
            disabled={!canConfigure}
            placeholder="https://github.com/acme/auto-ops-jobs.git"
            className={inputCls + " mb-4"}
          />
          <div className="mb-4 grid gap-4 sm:grid-cols-2">
            <div>
              <label className="mb-1.5 block text-xs font-medium text-slate-500">
                Branch
              </label>
              <input
                value={branch}
                onChange={(e) => setBranch(e.target.value)}
                disabled={!canConfigure}
                className={inputCls}
              />
            </div>
            <div>
              <label className="mb-1.5 block text-xs font-medium text-slate-500">
                Path in repo
              </label>
              <input
                value={basePath}
                onChange={(e) => setBasePath(e.target.value)}
                disabled={!canConfigure}
                placeholder="automation"
                className={inputCls}
              />
            </div>
          </div>
          <div className="mb-4 grid gap-4 sm:grid-cols-2">
            <div>
              <label className="mb-1.5 block text-xs font-medium text-slate-500">
                Username (optional)
              </label>
              <input
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                disabled={!canConfigure}
                placeholder="git username for the token"
                className={inputCls}
              />
            </div>
            <div>
              <label className="mb-1.5 block text-xs font-medium text-slate-500">
                Access token{" "}
                {storedTokenApplies && (
                  <span className="text-emerald-600">
                    (stored — blank keeps it)
                  </span>
                )}
                {tokenRequired && (
                  <span className="text-amber-600">(required)</span>
                )}
              </label>
              <input
                type="password"
                value={clearToken ? "" : token}
                onChange={(e) => setToken(e.target.value)}
                disabled={!canConfigure || clearToken}
                placeholder={
                  clearToken
                    ? "no credentials"
                    : storedTokenApplies
                      ? "••••••••"
                      : "ghp_…"
                }
                className={inputCls + (clearToken ? " opacity-60" : "")}
              />
            </div>
          </div>
          {canConfigure && hasToken && (
            <label className="mb-4 flex items-start gap-2 text-xs text-slate-600">
              <input
                type="checkbox"
                checked={clearToken}
                onChange={(e) => setClearToken(e.target.checked)}
                className="mt-0.5"
              />
              <span>
                This repository needs no credentials — remove the stored access
                token.
              </span>
            </label>
          )}
          {tokenRequired && (
            <p className="mb-4 rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-700">
              The repository URL changed. The stored token was issued for{" "}
              <span className="font-mono">{savedRepoUrl}</span> and will not
              authenticate against the new repository — enter the access token
              for it, or tick the box above if the new repository is public.
            </p>
          )}
          {canConfigure && (
            <div className="mt-auto flex justify-end border-t border-slate-200 pt-5">
              <SmallButton
                icon="check"
                variant="primary"
                disabled={saving}
                onClick={saveConfig}
              >
                {saving ? "Saving…" : "Save repository settings"}
              </SmallButton>
            </div>
          )}
        </Card>

        <Card className="flex flex-col p-6">
          <h3 className="mb-1 text-sm font-semibold text-slate-900">Sync</h3>
          <p className="mb-5 text-xs leading-relaxed text-slate-500">
            Definitions move between this project and the repository on demand.
            Plan limits apply to imported items.
          </p>

          {!configured && (
            <p className="mb-4 rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-700">
              Save the repository settings first.
            </p>
          )}
          {configured && repoChanged && (
            <p className="mb-4 rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-700">
              Unsaved repository URL — sync still targets{" "}
              <span className="font-mono">{savedRepoUrl}</span>. Save the
              settings first.
            </p>
          )}

          <div className="space-y-3">
            <div className="rounded-xl border border-slate-200 bg-white p-4">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <h4 className="text-sm font-semibold text-slate-900">
                    Export to Git
                  </h4>
                  <p className="mt-1 text-xs leading-relaxed text-slate-500">
                    Commits and pushes this project's current definitions.
                    Deleted jobs disappear from the repository too.
                  </p>
                </div>
                <div className="shrink-0">
                  <SmallButton
                    icon="arrow-right"
                    variant="primary"
                    disabled={!configured || repoChanged || !!syncing}
                    onClick={runExport}
                  >
                    {syncing === "export" ? "Exporting…" : "Export"}
                  </SmallButton>
                </div>
              </div>
            </div>

            <div className="rounded-xl border border-slate-200 bg-white p-4">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <h4 className="text-sm font-semibold text-slate-900">
                    Import from Git
                  </h4>
                  <p className="mt-1 text-xs leading-relaxed text-slate-500">
                    Reads the definitions back. New ones are created; existing
                    ones follow the conflict strategy.
                  </p>
                </div>
                <div className="shrink-0">
                  <SmallButton
                    icon="doc"
                    disabled={!configured || repoChanged || !!syncing}
                    onClick={runImport}
                  >
                    {syncing === "import" ? "Importing…" : "Import"}
                  </SmallButton>
                </div>
              </div>
              <label className="mt-3 block text-xs font-medium text-slate-500">
                Conflict strategy
                <select
                  value={strategy}
                  onChange={(e) => setStrategy(e.target.value)}
                  className={inputCls + " mt-1.5"}
                >
                  <option value="OVERWRITE">OVERWRITE — repo wins</option>
                  <option value="SKIP">SKIP — keep local</option>
                </select>
              </label>
            </div>
          </div>

          {result && (
            <div className="mt-4 rounded-xl border border-slate-200 bg-white p-4 text-sm text-slate-700">
              {result.kind === "export" ? (
                result.pushed ? (
                  <p>
                    <Icon
                      name="check"
                      size={14}
                      className="mr-1 inline text-emerald-600"
                    />
                    Pushed {result.jobs} job(s) and {result.workflows}{" "}
                    workflow(s) — commit{" "}
                    <span className="font-mono text-xs">
                      {String(result.commitId).slice(0, 10)}
                    </span>
                  </p>
                ) : (
                  <p>Repository already matches — no commit created.</p>
                )
              ) : (
                <>
                  <p>
                    Created {result.created} · Updated {result.updated} ·
                    Skipped {result.skipped}
                  </p>
                  {result.errors?.length > 0 && (
                    <ul className="mt-2 list-inside list-disc text-xs text-red-600">
                      {result.errors.map((err, i) => (
                        <li key={i} className="font-mono">
                          {err}
                        </li>
                      ))}
                    </ul>
                  )}
                </>
              )}
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}
