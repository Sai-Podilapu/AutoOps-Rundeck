import React, { useEffect, useMemo, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import {
  PageHeader,
  Card,
  Toolbar,
  Chip,
  SmallButton,
  Pagination,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";

/** Shared with the inventory page, so the two type filters cannot drift. */
export const KINDS = [
  { id: "All", label: "All types" },
  { id: "script", label: "Scripts" },
  { id: "workflow", label: "Workflows" },
  { id: "agent", label: "Agents" },
];

export default function Library() {
  const { pushToast, can } = useStore();
  const navigate = useNavigate();
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [cat, setCat] = useState("All");
  const [kind, setKind] = useState("All");
  const [selected, setSelected] = useState([]);
  const [importing, setImporting] = useState(false);

  const load = async () => {
    setLoading(true);
    try {
      const list = await api.listLibrary();
      setItems(Array.isArray(list) ? list : []);
    } catch (err) {
      pushToast(err.message || "Could not load library", "red");
    } finally {
      setLoading(false);
    }
  };
  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Titles already present in this workspace (owned copies) — used to dedupe.
  const ownedTitles = useMemo(
    () =>
      new Set(items.filter((i) => i.owned).map((i) => i.title.toLowerCase())),
    [items],
  );

  // Catalog = managed (provider) templates the tenant can import.
  const managed = items.filter((i) => i.managed);
  const categories = ["All", ...new Set(managed.map((i) => i.category))];
  const visible = managed.filter(
    (i) =>
      (cat === "All" || i.category === cat) &&
      (kind === "All" || i.type === kind),
  );

  const isImported = (i) => ownedTitles.has(i.title.toLowerCase());
  /**
   * Only SCRIPTS are importable. Workflows and agents are authored by the
   * provider and delivered sealed by a rollout, so core-service refuses to
   * clone them (403 rollout_only) — offering an Import button on one produces
   * a red toast and nothing else. Say where it comes from instead.
   */
  const isProviderDelivered = (i) => i.type !== "script";
  const selectable = (i) => !isImported(i) && !i.locked && !isProviderDelivered(i);

  const toggle = (id) =>
    setSelected((s) =>
      s.includes(id) ? s.filter((x) => x !== id) : [...s, id],
    );

  const importSelected = async () => {
    if (selected.length === 0) return;
    setImporting(true);
    let ok = 0;
    for (const id of selected) {
      try {
        await api.cloneLibraryItem(id);
        ok += 1;
      } catch (err) {
        pushToast(err.message || "An item could not be imported", "red");
      }
    }
    if (ok)
      pushToast(
        `Imported ${ok} item${ok > 1 ? "s" : ""} to your workspace`,
        "emerald",
      );
    setSelected([]);
    await load();
    setImporting(false);
  };

  const importOne = async (i) => {
    try {
      await api.cloneLibraryItem(i.id);
      pushToast(`Imported “${i.title}””`.replace("””", "”"), "emerald");
      await load();
    } catch (err) {
      pushToast(err.message || "Could not import item", "red");
    }
  };

  const owned = items.filter((i) => i.owned);
  const ownedCount = owned.length;

  const [page, setPage] = useState(1);
  const pageSize = 6;
  
  useEffect(() => {
    setPage(1);
  }, [cat, kind]);

  const totalPages = Math.ceil(visible.length / pageSize) || 1;
  const currentPage = Math.min(page, totalPages);
  const pagedVisible = visible.slice((currentPage - 1) * pageSize, currentPage * pageSize);

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Library"
        subtitle="Ready-made scripts, templates and workflows — maintained by AutoOps"
        actions={
          <div className="flex items-center gap-2">
            <SmallButton
              icon="check"
              onClick={() => navigate("/app/library/inventory")}
              title="What this workspace already owns"
            >
              My inventory ({ownedCount})
            </SmallButton>
            {/* Scripts are the one type this workspace may author. */}
            {can("authorScript") && (
              <SmallButton icon="plus" onClick={() => navigate("/app/library/script/new")}>
                New script
              </SmallButton>
            )}
            {selected.length > 0 && (
              <SmallButton
                icon="plus"
                variant="primary"
                onClick={importSelected}
                disabled={importing}
              >
                {importing
                  ? "Importing…"
                  : `Import selected (${selected.length})`}
              </SmallButton>
            )}
          </div>
        }
      />

      <Toolbar
        placeholder="Search the library…"
        right={categories.map((c) => (
          <button
            key={c}
            onClick={() => setCat(c)}
            className={`rounded-lg px-3 py-1.5 text-xs font-medium transition ${cat === c ? "bg-slate-50 text-slate-900" : "text-slate-500 hover:bg-slate-100 hover:text-slate-900"}`}
          >
            {c}
          </button>
        ))}
      />

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <span className="text-xs font-medium text-slate-500">
          Filter by type
        </span>
        {KINDS.map((k) => (
          <button
            key={k.id}
            onClick={() => setKind(k.id)}
            className={`rounded-lg px-3 py-1.5 text-xs font-medium transition ${kind === k.id ? "bg-slate-900 text-white" : "border border-slate-200 text-slate-500 hover:text-slate-900"}`}
          >
            {k.label}
          </button>
        ))}
      </div>

      {loading ? (
        <p className="text-sm text-slate-500">Loading library…</p>
      ) : visible.length === 0 ? (
        <Card className="p-10 text-center text-sm text-slate-500">
          No templates available yet.
        </Card>
      ) : (
        <>
          <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
            {pagedVisible.map((it) => {
              const imported = isImported(it);
              const canSelect = selectable(it);
              const checked = selected.includes(it.id);
              return (
                <Card
                  key={it.id}
                  className={`relative flex h-full flex-col p-5 transition duration-300 ${it.locked ? "opacity-80" : "hover:-translate-y-1 hover:border-blue-500"} ${checked ? "border-slate-300 ring-1 ring-slate-300" : ""}`}
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
                    <div className="flex items-center gap-1.5">
                      {it.premium && (
                        <span className="rounded-full border border-violet-400/30 bg-violet-400/10 px-2 py-0.5 text-[10px] font-semibold text-violet-600">
                          Premium
                        </span>
                      )}
                      {canSelect && (
                        <input
                          type="checkbox"
                          checked={checked}
                          onChange={() => toggle(it.id)}
                          className="h-4 w-4 cursor-pointer accent-cyan-400"
                          aria-label={`Select ${it.title}`}
                        />
                      )}
                    </div>
                  </div>
                  <h3 className="mt-3 text-base font-semibold text-slate-900">
                    {it.title}
                  </h3>
                  <p className="mt-1 flex-1 text-sm text-slate-500">
                    {it.description || "No description provided."}
                  </p>
                  <div className="mt-3 flex items-center justify-between text-xs text-slate-500">
                    <Chip>{it.category}</Chip>
                    <span>{(it.installs || 0).toLocaleString()} installs</span>
                  </div>

                  {it.locked ? (
                    <Link
                      to="/app/billing"
                      className="mt-4 flex items-center justify-center gap-2 rounded-lg border border-slate-200 bg-slate-50 py-2 text-sm font-semibold text-slate-600 transition hover:border-blue-500 hover:text-slate-900"
                    >
                      <Icon name="lock" size={15} /> Upgrade to unlock
                    </Link>
                  ) : imported ? (
                    <div className="mt-4 flex items-center justify-center gap-2 rounded-lg border border-emerald-400/30 bg-emerald-400/[0.06] py-2 text-sm font-semibold text-emerald-600">
                      <Icon name="check" size={15} /> In your workspace
                    </div>
                  ) : isProviderDelivered(it) ? (
                    <div
                      className="mt-4 flex items-center justify-center gap-2 rounded-lg border border-slate-200 bg-slate-50 py-2 text-center text-sm font-semibold text-slate-500"
                      title={`${
                        it.type === "agent" ? "Agents" : "Workflows"
                      } are built by your provider and delivered to your workspace — ask them to roll this one out.`}
                    >
                      <Icon name="sparkles" size={15} /> Delivered by your provider
                    </div>
                  ) : (
                    <button
                      onClick={() => importOne(it)}
                      className="mt-4 flex items-center justify-center gap-2 rounded-lg bg-gradient-to-r from-slate-900 to-slate-900 py-2 text-sm font-semibold text-white transition hover:brightness-110"
                    >
                      <Icon name="plus" size={15} /> Import
                    </button>
                  )}
                </Card>
              );
            })}
          </div>
          <div className="mt-6">
            <Pagination
              page={currentPage}
              pageSize={pageSize}
              totalItems={visible.length}
              onPageChange={setPage}
            />
          </div>
        </>
      )}

      <p className="mt-6 text-center text-xs text-slate-600">
        Importing copies a script into your workspace, where you can edit it.
        Items already in your workspace are marked and can’t be imported twice.
        Workflows and agents are built by your provider and delivered ready to
        run — ask them to roll one out to you.
      </p>
    </div>
  );
}
