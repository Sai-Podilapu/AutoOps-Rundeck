import React, { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { PageHeader, Card, Chip, SmallButton } from "../../components/app/appui";
import Icon from "../../components/Icon";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";
import { KINDS } from "./Library";

/**
 * What this workspace HAS — the other half of the Library, which answers what
 * it can GET.
 *
 * <p>A page rather than a panel over the catalog. The two lists are read at
 * different moments: you browse the marketplace to find something new, and you
 * come here to change something you already have. Stacking the second under
 * the first meant it sat below 36 pages of catalog, where nobody found it.
 *
 * <p>Only SCRIPTS can appear here, and that is the provider-authored model
 * rather than a gap: {@code LibraryService.list} marks an item owned when it
 * carries this tenant's id, and {@code RolloutService} refuses to write one for
 * a workflow or an agent — it builds those in workflow-service and
 * agent-service instead, attached to a project. The Workflows and Agents
 * filters therefore say where those actually live rather than showing an
 * unexplained empty grid.
 */
export default function Inventory() {
  const { pushToast, can } = useStore();
  const navigate = useNavigate();
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [kind, setKind] = useState("All");

  useEffect(() => {
    let cancelled = false;
    api
      .listLibrary()
      .then((list) => {
        if (!cancelled) setItems(Array.isArray(list) ? list : []);
      })
      .catch((err) => {
        if (!cancelled)
          pushToast(err.message || "Could not load your inventory", "red");
      })
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const owned = items.filter((i) => i.owned);
  const visible = owned.filter((i) => kind === "All" || i.type === kind);

  // Per-filter counts, so an empty tab is legible before it is opened.
  const countFor = (id) =>
    id === "All" ? owned.length : owned.filter((i) => i.type === id).length;

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="My inventory"
        subtitle="Everything this workspace owns — yours to change. Editing a copy never touches your provider’s original."
        actions={
          <div className="flex items-center gap-2">
            <SmallButton icon="chevron" onClick={() => navigate("/app/library")}>
              Back to library
            </SmallButton>
            {can("authorScript") && (
              <SmallButton
                icon="plus"
                variant="primary"
                onClick={() => navigate("/app/library/script/new")}
              >
                New script
              </SmallButton>
            )}
          </div>
        }
      />

      <div className="mb-5 flex flex-wrap items-center gap-2">
        <span className="text-xs font-medium text-slate-500">Filter by type</span>
        {KINDS.map((k) => (
          <button
            key={k.id}
            onClick={() => setKind(k.id)}
            className={`rounded-lg px-3 py-1.5 text-xs font-medium transition ${kind === k.id ? "bg-slate-900 text-white" : "border border-slate-200 text-slate-500 hover:text-slate-900"}`}
          >
            {k.label} ({countFor(k.id)})
          </button>
        ))}
      </div>

      {loading ? (
        <p className="text-sm text-slate-500">Loading your inventory…</p>
      ) : visible.length === 0 ? (
        <Card className="p-10 text-center">
          {kind === "workflow" || kind === "agent" ? (
            <>
              <p className="text-sm text-slate-500">
                {kind === "workflow" ? "Workflows" : "Agents"} are built by your
                provider and delivered to a project, not held here.
              </p>
              <p className="mt-1 text-xs text-slate-400">
                Open Projects to see the ones rolled out to you — ask your
                provider to roll out another.
              </p>
              <button
                onClick={() => navigate("/app/projects")}
                className="mt-4 inline-flex items-center gap-2 rounded-lg border border-slate-200 bg-slate-50 px-4 py-2 text-sm font-semibold text-slate-700 transition hover:border-blue-500 hover:text-slate-900"
              >
                <Icon name="folder" size={15} /> Go to Projects
              </button>
            </>
          ) : (
            <>
              <p className="text-sm text-slate-500">Nothing here yet.</p>
              <p className="mt-1 text-xs text-slate-400">
                Import a script from the library, or write your own — it lands
                here.
              </p>
              <button
                onClick={() => navigate("/app/library")}
                className="mt-4 inline-flex items-center gap-2 rounded-lg border border-slate-200 bg-slate-50 px-4 py-2 text-sm font-semibold text-slate-700 transition hover:border-blue-500 hover:text-slate-900"
              >
                <Icon name="book" size={15} /> Browse the library
              </button>
            </>
          )}
        </Card>
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {visible.map((it) => (
            <Card
              key={it.id}
              className="flex h-full flex-col p-5 transition duration-300 hover:-translate-y-1 hover:border-blue-500"
            >
              <div className="flex items-start justify-between">
                <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-slate-50 text-slate-900">
                  <Icon
                    name={
                      it.type === "agent"
                        ? "robot"
                        : it.type === "workflow"
                          ? "blocks"
                          : "terminal"
                    }
                    size={20}
                  />
                </span>
                <Chip>{it.category}</Chip>
              </div>
              <h3 className="mt-3 text-base font-semibold text-slate-900">
                {it.title}
              </h3>
              <p className="mt-1 flex-1 text-sm text-slate-500">
                {it.description || "No description provided."}
              </p>
              {it.type !== "script" ? (
                <div className="mt-4 flex items-center justify-center gap-2 rounded-lg border border-slate-200 bg-slate-50 py-2 text-sm font-semibold text-slate-500">
                  <Icon name="sparkles" size={15} /> Delivered by your provider
                </div>
              ) : can("authorScript") ? (
                <button
                  onClick={() => navigate(`/app/library/script/${it.id}`)}
                  className="mt-4 flex items-center justify-center gap-2 rounded-lg border border-slate-200 bg-slate-50 py-2 text-sm font-semibold text-slate-700 transition hover:border-blue-500 hover:text-slate-900"
                >
                  <Icon name="pencil" size={15} /> Edit script
                </button>
              ) : (
                <p className="mt-4 text-center text-xs text-slate-400">
                  Ask an admin or operator to change this
                </p>
              )}
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
