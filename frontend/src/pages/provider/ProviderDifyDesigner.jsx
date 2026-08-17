import React, { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { PageHeader, Card, SmallButton } from "../../components/app/appui";
import Icon from "../../components/Icon";
import { difyApi } from "../../lib/dify/difyApi";
import { useStore } from "../../store/store";

/**
 * "New workflow" — the entry point into the Dify-backed designer.
 *
 * There is ONE workflow concept on this platform and Dify is the engine behind
 * it, so this creates a Dify app first and then hands off to the designer:
 * the designer edits a DRAFT that has to belong to a real app, and inventing a
 * client-side placeholder would mean the first save could fail after the
 * provider had already built the graph.
 *
 * <p>Dify being unconfigured is handled here rather than left to blow up
 * inside the canvas — core-service answers 503 {@code dify_not_configured}
 * when DIFY_BASE_URL / DIFY_API_KEY are unset, and the operator needs to see
 * that as a setup instruction, not a designer crash.
 */
export default function ProviderDifyDesigner() {
  const { pushToast } = useStore();
  const navigate = useNavigate();

  const [name, setName] = useState("");
  const [creating, setCreating] = useState(false);
  const [probe, setProbe] = useState("checking"); // checking | ready | error
  const [problem, setProblem] = useState(null);

  // Ask Dify for the app list purely to find out whether the bridge is wired.
  useEffect(() => {
    let alive = true;
    difyApi
      .listApps()
      .then(() => alive && setProbe("ready"))
      .catch((e) => {
        if (!alive) return;
        setProbe("error");
        setProblem(e.message || "Dify is unreachable");
      });
    return () => {
      alive = false;
    };
  }, []);

  const create = async () => {
    if (!name.trim()) {
      setProblem("Give the workflow a name.");
      return;
    }
    setCreating(true);
    setProblem(null);
    try {
      const app = await difyApi.createApp({ name: name.trim(), mode: "workflow" });
      if (!app?.id) throw new Error("Dify did not return an app id");
      navigate(`/provider/library/workflow/${app.id}`);
    } catch (e) {
      setProblem(e.message || "Could not create the workflow");
      pushToast(e.message || "Could not create the workflow", "red");
    } finally {
      setCreating(false);
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="New workflow"
        subtitle="Designed here, executed by Dify, rolled out to your customers sealed"
        actions={
          <SmallButton icon="chevron" onClick={() => navigate("/provider/library")}>
            Library
          </SmallButton>
        }
      />

      <div className="mx-auto max-w-xl">
        {probe === "error" ? (
          <Card className="border-amber-400/30 bg-amber-400/[0.04] p-6">
            <p className="flex items-start gap-2.5 text-sm text-amber-800">
              <Icon name="warning" size={16} className="mt-0.5 shrink-0" />
              <span>
                <strong className="block text-slate-900">Dify is not connected</strong>
                <span className="mt-1 block text-xs leading-relaxed">{problem}</span>
                <span className="mt-2 block text-xs leading-relaxed">
                  Set <code className="font-mono">DIFY_BASE_URL</code> and{" "}
                  <code className="font-mono">DIFY_API_KEY</code> in{" "}
                  <code className="font-mono">./.env</code>, then restart
                  core-service. The key stays server-side — the browser never
                  receives it.
                </span>
              </span>
            </p>
          </Card>
        ) : (
          <Card className="p-6">
            <label className="mb-1.5 block text-xs font-semibold text-slate-700">
              Workflow name
            </label>
            <input
              autoFocus
              value={name}
              onChange={(e) => setName(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && create()}
              placeholder="Payment exception repair"
              disabled={probe !== "ready"}
              className="w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-violet-400 focus:ring-2 focus:ring-violet-400/20 disabled:opacity-50"
            />
            <p className="mt-2 text-[11px] leading-relaxed text-slate-500">
              Creates the app in Dify and opens the designer. Publish it to the
              catalog when it is ready, then roll it out from the Library.
            </p>
            <div className="mt-4 flex justify-end">
              <SmallButton
                icon="check"
                variant="primary"
                onClick={create}
                disabled={creating || probe !== "ready"}
              >
                {probe === "checking"
                  ? "Connecting to Dify…"
                  : creating
                    ? "Creating…"
                    : "Create and design"}
              </SmallButton>
            </div>
            {problem && probe === "ready" && (
              <p className="mt-3 text-sm text-red-600">{problem}</p>
            )}
          </Card>
        )}
      </div>
    </div>
  );
}
