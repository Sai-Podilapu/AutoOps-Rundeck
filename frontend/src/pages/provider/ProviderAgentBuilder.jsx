import React, { useState } from "react";
import { useNavigate } from "react-router-dom";
import { PageHeader, Card, SmallButton } from "../../components/app/appui";
import Icon from "../../components/Icon";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";

const inputCls =
  "w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-violet-400 focus:ring-2 focus:ring-violet-400/20 hover:border-blue-500";

const labelCls = "mb-1.5 block text-xs font-semibold text-slate-700";

/**
 * Build an agent for the platform catalog, ready to roll out to customers.
 *
 * The persona (`instructions`) is the product: once rolled out, agent-service
 * withholds it from the receiving tenant, so what is written here is never
 * visible to the customer running it.
 *
 * <p><b>Why there is no tool picker here.</b> An agent's allow-list references
 * concrete jobs and workflows BY ID, and those ids belong to one customer's
 * project — they do not exist at catalog time and differ per customer. A
 * picker here could only offer ids that would fail validation on delivery.
 * Catalog agents are therefore authored with an empty allow-list (an agent
 * that can operate nothing, which is the safe default), and tools are granted
 * per customer against their real project.
 */
export default function ProviderAgentBuilder() {
  const { pushToast } = useStore();
  const navigate = useNavigate();

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [category, setCategory] = useState("General");
  const [model, setModel] = useState("claude-sonnet-5");
  const [instructions, setInstructions] = useState("");
  const [premium, setPremium] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  const save = async () => {
    if (!title.trim()) {
      setError("Give the agent a name.");
      return;
    }
    if (!instructions.trim()) {
      setError("An agent with no operating brief has nothing to follow.");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await api.providerCreateLibrary({
        title: title.trim(),
        type: "agent",
        category: category || "General",
        premium,
        description: description.trim(),
        // The catalog stores an agent's spec in the same `definition` column a
        // workflow stores its canvas in. RolloutService reads these fields
        // back out when it delivers to a customer.
        definition: JSON.stringify({
          nodes: [],
          description: description.trim(),
          model: model.trim(),
          instructions: instructions.trim(),
          tools: [],
        }),
      });
      pushToast(`Agent "${title}" added to the catalog`, "emerald");
      navigate("/provider/library");
    } catch (err) {
      setError(err.message || "Could not save the agent");
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Build an agent"
        subtitle="Catalog agents are yours — customers run them without seeing the brief"
        actions={
          <>
            <SmallButton icon="chevron" onClick={() => navigate("/provider/library")}>
              Cancel
            </SmallButton>
            <SmallButton
              icon="check"
              variant="primary"
              onClick={save}
              disabled={saving}
            >
              {saving ? "Saving…" : "Save to catalog"}
            </SmallButton>
          </>
        }
      />

      <div className="grid gap-6 lg:grid-cols-3">
        <Card className="p-6 lg:col-span-2">
          <div className="space-y-4">
            <div>
              <label className={labelCls}>Name</label>
              <input
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                placeholder="Banking Ops Copilot"
                className={inputCls}
              />
            </div>

            <div>
              <label className={labelCls}>
                Description{" "}
                <span className="font-normal text-slate-400">
                  — customers DO see this
                </span>
              </label>
              <input
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                placeholder="On-call assistant for the payments night shift."
                className={inputCls}
              />
            </div>

            <div>
              <label className={labelCls}>
                Operating brief{" "}
                <span className="font-normal text-violet-600">
                  — withheld from customers
                </span>
              </label>
              <textarea
                value={instructions}
                onChange={(e) => setInstructions(e.target.value)}
                rows={12}
                placeholder={
                  "You assist the night-shift operations team.\n\n" +
                  "You may explain failures and rerun allowlisted jobs.\n" +
                  "You must never post financial entries or release a payment —\n" +
                  "those require a human approval gate."
                }
                className={`${inputCls} resize-none font-mono text-xs leading-relaxed`}
              />
              <p className="mt-1.5 text-[11px] text-slate-500">
                This is the product. Once rolled out, the API refuses to send it
                back to the tenant running the agent.
              </p>
            </div>
          </div>
        </Card>

        <div className="space-y-6">
          <Card className="p-6">
            <h3 className="mb-4 text-sm font-semibold text-slate-900">Delivery</h3>
            <div className="space-y-4">
              <div>
                <label className={labelCls}>Model</label>
                <input
                  value={model}
                  onChange={(e) => setModel(e.target.value)}
                  placeholder="claude-sonnet-5"
                  className={inputCls}
                />
                <p className="mt-1 text-[11px] text-slate-500">
                  Shown to customers — they are entitled to know what runs over
                  their data.
                </p>
              </div>

              <div>
                <label className={labelCls}>Category</label>
                <select
                  value={category}
                  onChange={(e) => setCategory(e.target.value)}
                  className={inputCls}
                >
                  <option>General</option>
                  <option>Ops</option>
                  <option>Security</option>
                  <option>Compliance</option>
                  <option>FinOps</option>
                  <option>SRE</option>
                </select>
              </div>

              <label className="flex cursor-pointer items-center gap-2.5">
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
            </div>
          </Card>

          <Card className="border-amber-400/20 bg-amber-400/[0.04] p-6">
            <p className="flex items-start gap-2 text-xs leading-relaxed text-amber-800">
              <Icon name="warning" size={14} className="mt-0.5 shrink-0" />
              <span>
                Catalog agents start with <strong>no tools</strong>, so a
                freshly delivered agent can operate nothing. An allow-list
                names specific jobs and workflows by id, and those exist only
                inside a customer&apos;s project — so tools are granted per
                customer after rollout, never here.
              </span>
            </p>
          </Card>
        </div>
      </div>

      {error && (
        <p className="mt-4 rounded-lg border border-red-400/30 bg-red-400/5 px-3 py-2 text-sm text-red-600">
          {error}
        </p>
      )}
    </div>
  );
}
