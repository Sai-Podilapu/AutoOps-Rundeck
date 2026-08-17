import React, { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { PageHeader, Card, SmallButton } from "../../components/app/appui";
import Icon from "../../components/Icon";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";

const inputCls =
  "w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-violet-400 focus:ring-2 focus:ring-violet-400/20 hover:border-blue-500";

const labelCls = "mb-1.5 block text-xs font-semibold text-slate-700";

const STARTER = `# Runs on the target node via the AutoOps agent.
# Exit non-zero to fail the step.

$ErrorActionPreference = "Stop"

Write-Output "Starting..."

# your script here

Write-Output "Done."
`;

/** Shells the catalog offers. The value is the step type job-service runs. */
const SHELLS = [
  { id: "powershell", label: "PowerShell", ext: ".ps1", comment: "#" },
  { id: "bash", label: "Bash", ext: ".sh", comment: "#" },
  { id: "python", label: "Python", ext: ".py", comment: "#" },
];

/** Generous — the column is MEDIUMTEXT — but a picked-by-mistake archive is not a script. */
const MAX_IMPORT_CHARS = 256 * 1024;

/**
 * The {steps:[…]} envelope back into the two things the editor edits. A
 * definition written by hand (or by an older build) may not match, so this
 * returns null rather than guessing and silently discarding someone's script.
 */
function parseDefinition(definition) {
  try {
    const step = (JSON.parse(definition)?.steps || [])[0];
    if (!step || typeof step.value !== "string") return null;
    return {
      shell: SHELLS.some((s) => s.id === step.type) ? step.type : "bash",
      body: step.value,
    };
  } catch {
    return null;
  }
}

/**
 * Author a script — for the platform catalog, or for one workspace.
 *
 * Two panels because the two halves are genuinely different work: naming and
 * classifying the script on the left, WRITING it on the right. The old modal
 * put a one-line "definition" JSON field in a 512px dialog and asked for
 * hand-assembled `{"steps":[{"value":"..."}]}` around the code — which is how
 * you get escaped newlines in a shipped script. The editor writes plain script
 * text; the envelope is assembled on save.
 *
 * <p>ONE component for both audiences deliberately. A tenant editing the copy
 * it imported is doing the same job as a provider editing the original, and
 * two implementations of a code editor drift — the tab handling, the gutter
 * and the shell inference would have to be fixed twice.
 *
 * @param audience "provider" writes the platform catalog (and may price an
 *   item premium); "tenant" writes scripts this workspace owns.
 */
export default function ScriptEditor({ audience = "provider" }) {
  const { pushToast, can } = useStore();
  const navigate = useNavigate();
  const { id } = useParams();
  const editorRef = useRef(null);
  const gutterRef = useRef(null);
  const fileRef = useRef(null);

  const isProvider = audience === "provider";
  const editing = Boolean(id);
  const backTo = isProvider ? "/provider/library/scripts" : "/app/library";

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [category, setCategory] = useState("Maintenance");
  const [shell, setShell] = useState("powershell");
  const [premium, setPremium] = useState(false);
  const [body, setBody] = useState(STARTER);
  const [saving, setSaving] = useState(false);
  const [loading, setLoading] = useState(editing);
  const [error, setError] = useState(null);
  const [knownCategories, setKnownCategories] = useState([]);

  // One read serves both jobs: the item being edited, and the categories
  // already in use. It is the same list the library page renders, so there is
  // no second read path to keep in step.
  useEffect(() => {
    let cancelled = false;
    api
      .listLibrary()
      .then((rows) => {
        if (cancelled) return;
        const list = rows || [];

        // Offered as suggestions on the category field. Typing "AWS " or "Aws"
        // would otherwise open a second near-identical category that splits the
        // library filter in two.
        setKnownCategories(
          [...new Set(list.map((r) => (r.category || "").trim()).filter(Boolean))].sort(
            (a, b) => a.localeCompare(b),
          ),
        );

        if (!editing) return;
        const item = list.find((r) => String(r.id) === String(id));
        if (!item) {
          setError("That script is no longer in the library.");
          return;
        }
        setTitle(item.title || "");
        setDescription(item.description || "");
        setCategory(item.category || "General");
        setPremium(Boolean(item.premium));
        const parsed = parseDefinition(item.definition);
        if (parsed) {
          setShell(parsed.shell);
          setBody(parsed.body);
        } else {
          // Say so rather than opening the starter template over their script.
          setError(
            "This script's stored definition could not be read, so the editor is empty. Saving will replace it.",
          );
          setBody("");
        }
      })
      .catch((err) => {
        // Only an edit genuinely needs this response. Losing the category
        // suggestions must not block writing a new script from scratch.
        if (!cancelled && editing) setError(err.message || "Could not load the script");
      })
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
  }, [editing, id]);

  const active = SHELLS.find((s) => s.id === shell) || SHELLS[0];
  const fileName = useMemo(() => {
    const stem =
      title
        .trim()
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-|-$/g, "") || "untitled";
    return stem + active.ext;
  }, [title, active.ext]);

  const lines = body.split("\n");

  // Tab must indent, not escape the field — a code editor that loses focus on
  // Tab is unusable for writing anything real.
  const onKeyDown = (e) => {
    if (e.key !== "Tab") return;
    e.preventDefault();
    const el = e.target;
    const { selectionStart: start, selectionEnd: end } = el;
    const next = body.slice(0, start) + "    " + body.slice(end);
    setBody(next);
    requestAnimationFrame(() => {
      el.selectionStart = el.selectionEnd = start + 4;
    });
  };

  /**
   * Import a script file rather than retyping it. The extension picks the
   * shell and the filename seeds the name, because those are exactly the two
   * things someone would otherwise set by hand straight afterwards.
   */
  const onImport = (e) => {
    const file = e.target.files?.[0];
    // Reset immediately: without this, picking the SAME file twice fires no
    // change event and the import silently does nothing the second time.
    e.target.value = "";
    if (!file) return;

    const reader = new FileReader();
    reader.onload = () => {
      const text = String(reader.result || "");
      if (text.length > MAX_IMPORT_CHARS) {
        setError(
          `${file.name} is ${Math.round(text.length / 1024)}KB — too large for a script. Import the file you meant, or trim it.`,
        );
        return;
      }
      if (text.includes("\u0000")) {
        setError(`${file.name} looks like a binary file, not a script.`);
        return;
      }
      setError(null);
      setBody(text);
      const ext = `.${(file.name.split(".").pop() || "").toLowerCase()}`;
      const guessed = SHELLS.find((s) => s.ext === ext);
      if (guessed) setShell(guessed.id);
      if (!title.trim()) setTitle(file.name.replace(/\.[^.]+$/, ""));
      pushToast(`Imported ${file.name}`, "emerald");
    };
    reader.onerror = () => setError(`Could not read ${file.name}.`);
    reader.readAsText(file);
  };

  const save = async () => {
    if (!title.trim()) {
      setError("Give the script a name.");
      return;
    }
    if (!body.trim()) {
      setError("The script is empty.");
      return;
    }
    setSaving(true);
    setError(null);
    // The catalog's runnable shape. One step carrying the whole script —
    // LibraryService requires a steps[] array, and job-service runs `value`
    // as the command body for the step's type.
    const definition = JSON.stringify({
      steps: [{ id: "script", type: active.id, label: title.trim(), value: body }],
    });
    const common = {
      title: title.trim(),
      category: category.trim() || "General",
      description: description.trim(),
      definition,
    };
    try {
      if (editing) {
        await (isProvider
          ? api.providerUpdateLibrary(id, { ...common, premium })
          : api.updateLibraryItem(id, common));
        pushToast(`"${title.trim()}" saved`, "emerald");
      } else if (isProvider) {
        await api.providerCreateLibrary({ ...common, type: "script", premium });
        pushToast(`"${title.trim()}" published to the catalog`, "emerald");
      } else {
        await api.createLibraryItem({ ...common, type: "script" });
        pushToast(`"${title.trim()}" added to your workspace`, "emerald");
      }
      navigate(backTo);
    } catch (err) {
      setError(err.message || "Could not save the script");
    } finally {
      setSaving(false);
    }
  };

  // The backend refuses either way; this keeps a viewer from typing a script
  // only to be told at the end that it was never theirs to save.
  if (!isProvider && can && !can("authorScript")) {
    return (
      <Card className="p-10 text-center text-sm text-slate-500">
        Your role can run scripts but not write them. An admin or operator in
        this workspace can create and edit scripts.
      </Card>
    );
  }

  return (
    <div className="animate-fade-up">
      <PageHeader
        title={editing ? "Edit script" : "New script"}
        subtitle={
          isProvider
            ? "Customers import scripts from your catalog and run them as job steps"
            : "Scripts your workspace owns — write your own, or adapt one you imported"
        }
        actions={
          <>
            <input
              ref={fileRef}
              type="file"
              accept=".sh,.ps1,.py,.bash,.txt"
              onChange={onImport}
              className="hidden"
              aria-hidden="true"
              tabIndex={-1}
            />
            <SmallButton icon="file" onClick={() => fileRef.current?.click()}>
              Import file
            </SmallButton>
            <SmallButton icon="chevron" onClick={() => navigate(backTo)}>
              Cancel
            </SmallButton>
            <SmallButton
              icon="check"
              variant="primary"
              onClick={save}
              disabled={saving || loading}
            >
              {saving ? "Saving…" : editing ? "Save changes" : "Save script"}
            </SmallButton>
          </>
        }
      />

      <div className="grid gap-6 lg:grid-cols-[minmax(0,320px)_minmax(0,1fr)]">
        {/* ── Left: script details ── */}
        <Card className="h-fit p-6">
          <h3 className="mb-4 text-sm font-semibold text-slate-900">Script details</h3>
          <div className="space-y-4">
            <div>
              <label className={labelCls} htmlFor="script-name">
                Name
              </label>
              <input
                id="script-name"
                autoFocus
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                placeholder="Nightly database backup"
                className={inputCls}
              />
            </div>

            <div>
              <label className={labelCls} htmlFor="script-description">
                Description
              </label>
              <textarea
                id="script-description"
                rows={3}
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                placeholder="What does it do, and when should it run?"
                className={`${inputCls} resize-none`}
              />
            </div>

            <div>
              <label className={labelCls} htmlFor="script-shell">
                Shell
              </label>
              <select
                id="script-shell"
                value={shell}
                onChange={(e) => setShell(e.target.value)}
                className={inputCls}
              >
                {SHELLS.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.label} ({s.ext})
                  </option>
                ))}
              </select>
            </div>

            <div>
              <label className={labelCls} htmlFor="script-category">
                Category
              </label>
              {/* A datalist, not a select: picking an existing category is the
                  common case, but a genuinely new one still has to be typeable
                  without an escape hatch like an "Other…" option. */}
              <input
                id="script-category"
                list="script-category-options"
                value={category}
                onChange={(e) => setCategory(e.target.value)}
                placeholder="Maintenance"
                className={inputCls}
              />
              <datalist id="script-category-options">
                {knownCategories.map((c) => (
                  <option key={c} value={c} />
                ))}
              </datalist>
              {knownCategories.length > 0 && (
                <p className="mt-1.5 text-[11px] text-slate-500">
                  {knownCategories.length} categor
                  {knownCategories.length === 1 ? "y" : "ies"} in use — pick one to
                  file this alongside them, or type a new name.
                </p>
              )}
            </div>

            {isProvider && (
              <label className="flex cursor-pointer items-center gap-2.5 pt-1">
                <input
                  type="checkbox"
                  checked={premium}
                  onChange={(e) => setPremium(e.target.checked)}
                  className="h-4 w-4 rounded border-slate-300 accent-violet-600"
                />
                <span className="text-sm text-slate-700">
                  Premium — Business plan and above
                </span>
              </label>
            )}

            <p className="border-t border-slate-200 pt-3 text-[11px] leading-relaxed text-slate-500">
              {isProvider
                ? "Scripts are the one catalog type customers own outright: they import a copy and are free to adapt it. Workflows and agents are rolled out sealed instead."
                : "This script belongs to your workspace. Editing a copy you imported never changes your provider's original."}
            </p>
          </div>
        </Card>

        {/* ── Right: the terminal ── */}
        <Card className="overflow-hidden p-0">
          <div className="flex items-center justify-between border-b border-slate-800 bg-slate-950 px-4 py-2.5">
            <div className="flex items-center gap-2">
              <span className="flex gap-1.5">
                <span className="h-2.5 w-2.5 rounded-full bg-red-400/70" />
                <span className="h-2.5 w-2.5 rounded-full bg-amber-400/70" />
                <span className="h-2.5 w-2.5 rounded-full bg-emerald-400/70" />
              </span>
              <span className="ml-1.5 flex items-center gap-1.5 font-mono text-xs text-slate-300">
                <Icon name="terminal" size={13} />
                {fileName}
              </span>
            </div>
            <div className="flex items-center gap-3 font-mono text-[10px] text-slate-500">
              <span>{active.label}</span>
              <span>
                {lines.length} {lines.length === 1 ? "line" : "lines"}
              </span>
              {!editing && (
                <button
                  type="button"
                  onClick={() => setBody(STARTER)}
                  title="Reset to the starter template"
                  className="transition hover:text-slate-300"
                >
                  <Icon name="refresh" size={12} />
                </button>
              )}
            </div>
          </div>

          {/* Fixed height, and the CODE scrolls — not the page. A 900-line
              script used to stretch the card to 900 lines tall, pushing Save
              off screen and leaving the details panel stranded beside a column
              of whitespace. Clamped rather than a flat pixel value so a tall
              monitor gets a taller editor without a short one overflowing. */}
          <div
            className="relative flex overflow-hidden bg-slate-950"
            style={{ height: "clamp(360px, calc(100vh - 22rem), 620px)" }}
          >
            {/* Gutter. aria-hidden: the line numbers are decoration, and a
                screen reader announcing "1 2 3 4" before the code is noise.
                overflow-hidden, but still a scroll container — the textarea's
                onScroll drives its scrollTop so the numbers track the code. */}
            <div
              ref={gutterRef}
              aria-hidden="true"
              className="shrink-0 select-none overflow-hidden border-r border-slate-800/80 px-3 py-4 text-right font-mono text-xs leading-6 text-slate-600"
            >
              {lines.map((_, i) => (
                <div key={i}>{i + 1}</div>
              ))}
            </div>
            <textarea
              ref={editorRef}
              value={loading ? "" : body}
              onChange={(e) => setBody(e.target.value)}
              onKeyDown={onKeyDown}
              onScroll={(e) => {
                // Both columns are line-height 6 with the same vertical
                // padding, so one scrollTop keeps them in lockstep.
                if (gutterRef.current)
                  gutterRef.current.scrollTop = e.currentTarget.scrollTop;
              }}
              // No soft wrap: one logical line must occupy exactly one visual
              // row, or line 19 in the gutter sits beside line 18's overflow.
              wrap="off"
              spellCheck={false}
              autoComplete="off"
              autoCorrect="off"
              autoCapitalize="off"
              disabled={loading}
              aria-label={`${active.label} script`}
              className="h-full flex-1 resize-none overflow-auto overscroll-contain border-0 bg-transparent px-4 py-4 font-mono text-xs leading-6 text-slate-100 caret-emerald-400 outline-none placeholder:text-slate-600"
            />
          </div>

          <div className="border-t border-slate-800 bg-slate-950 px-4 py-2 font-mono text-[10px] text-slate-500">
            Tab indents · runs on the target node via the AutoOps agent ·
            non-zero exit fails the step
          </div>
        </Card>
      </div>

      {error && (
        <p className="mt-4 rounded-lg border border-red-400/30 bg-red-400/5 px-3 py-2 text-sm text-red-600">
          {error}
        </p>
      )}
    </div>
  );
}
