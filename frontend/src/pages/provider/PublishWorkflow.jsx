import React, { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { PageHeader, Card, Chip, SmallButton } from "../../components/app/appui";
import Icon from "../../components/Icon";
import { api } from "../../lib/api";
import { difyApi } from "../../lib/dify/difyApi";
import { useStore } from "../../store/store";

/**
 * Turns a published Dify workflow into a catalog item customers can be given.
 *
 * <p><b>Why this screen exists.</b> Designing a workflow in Dify and offering
 * it to customers were two disconnected acts: the designer created an app in
 * Dify, and the catalog held hand-written JSON that had nothing to do with it.
 * A workflow could be designed, published and still be unrunnable, with no
 * screen that said so. This is the join.
 *
 * <p><b>What "runnable" means here.</b> The list comes from
 * {@code /api/dify/catalog}, which is every workflow this platform holds a
 * Service API key for — not every app in the Dify workspace. An app that was
 * never published, or whose {@code app-…} key was never configured, is absent
 * on purpose: publishing it would create a catalog entry that fails the first
 * time a customer presses Run.
 *
 * <p>The catalog item stores only {@code {"difyWorkflow":"<slug>"}}. The key
 * stays on the server — this page never sees one, and the definition is
 * rendered into a browser elsewhere in the provider console.
 */
export default function PublishWorkflow() {
  const navigate = useNavigate();
  const { pushToast } = useStore();
  const [entries, setEntries] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [publishing, setPublishing] = useState(null);

  const load = () => {
    setLoading(true);
    setError(null);
    difyApi
      .runnableCatalog()
      .then((rows) => setEntries(Array.isArray(rows) ? rows : []))
      .catch((err) => setError(err.message || "Could not reach Dify"))
      .finally(() => setLoading(false));
  };
  useEffect(load, []);

  const publish = async (entry) => {
    setPublishing(entry.slug);
    try {
      await api.providerCreateLibrary({
        title: entry.name || entry.slug,
        description: entry.description || "",
        category: "Workflows",
        type: "workflow",
        definition: JSON.stringify({ difyWorkflow: entry.slug }),
      });
      pushToast(`“${entry.name || entry.slug}” added to the catalog`, "emerald");
      navigate("/provider/library/workflows");
    } catch (err) {
      pushToast(err.message || "Could not publish this workflow", "red");
    } finally {
      setPublishing(null);
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Publish a workflow"
        subtitle="Dify workflows this platform can run — add one to the catalog to roll it out"
        actions={
          <>
            <SmallButton icon="refresh" onClick={load}>
              Refresh
            </SmallButton>
            <SmallButton icon="chevron" onClick={() => navigate("/provider/library")}>
              Back to library
            </SmallButton>
          </>
        }
      />

      {loading ? (
        <p className="text-sm text-slate-500">Reading the Dify workspace…</p>
      ) : error ? (
        <Card className="p-10 text-center">
          <p className="text-sm text-slate-500">{error}</p>
          <p className="mt-1 text-xs text-slate-400">
            Set DIFY_BASE_URL on core-service and restart it.
          </p>
        </Card>
      ) : entries.length === 0 ? (
        <Card className="p-10 text-center">
          <p className="text-sm text-slate-500">No runnable workflows yet.</p>
          <p className="mx-auto mt-2 max-w-xl text-xs leading-relaxed text-slate-400">
            A workflow appears here once it is <strong>published</strong> in Dify
            and its Service API key is configured on core-service — either
            <code className="mx-1 rounded bg-slate-100 px-1">
              DIFY_WORKFLOW_KEYS=slug=app-…
            </code>
            for all of them at once, or
            <code className="mx-1 rounded bg-slate-100 px-1">DIFY_WF_SLUG=app-…</code>
            one at a time. Restart core-service after adding a key.
          </p>
        </Card>
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {entries.map((entry) => (
            <Card key={entry.slug} className="flex h-full flex-col p-5">
              <div className="flex items-start justify-between">
                <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-slate-50 text-slate-900">
                  <Icon name="blocks" size={20} />
                </span>
                <Chip>{entry.slug}</Chip>
              </div>
              <h3 className="mt-3 text-base font-semibold text-slate-900">
                {entry.name || entry.slug}
              </h3>
              <p className="mt-1 flex-1 text-sm text-slate-500">
                {entry.description || "No description set in Dify."}
              </p>

              {/* The exact form the customer will be shown. Surfaced here so a
                  workflow that silently asks for nothing is obvious BEFORE it
                  is published — that is almost always an unpublished edit in
                  Dify rather than a workflow that genuinely takes no input. */}
              {entry.error ? (
                <p className="mt-3 rounded-lg border border-red-400/30 bg-red-400/5 px-3 py-2 text-xs text-red-600">
                  {entry.error}
                </p>
              ) : (
                <p className="mt-3 text-xs text-slate-500">
                  {entry.inputs?.length
                    ? `Asks for: ${entry.inputs
                        .map((i) => i.label + (i.required ? "*" : ""))
                        .join(", ")}`
                    : "Takes no input."}
                </p>
              )}

              <button
                onClick={() => publish(entry)}
                disabled={Boolean(entry.error) || publishing === entry.slug}
                className="mt-4 flex items-center justify-center gap-2 rounded-lg bg-slate-900 py-2 text-sm font-semibold text-white transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-40"
              >
                <Icon name="plus" size={15} />
                {publishing === entry.slug ? "Publishing…" : "Add to catalog"}
              </button>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
