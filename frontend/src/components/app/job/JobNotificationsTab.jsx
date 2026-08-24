import React from "react";
import { Card, Chip, SmallButton } from "../appui";
import Icon from "../../Icon";

const inputCls =
  "w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300";
const label = "mb-1.5 block text-xs font-medium text-slate-500";

// The five moments worth telling someone about. Named to match what an
// operator would say out loud, not what the engine calls them.
const TRIGGERS = [
  { id: "onstart", label: "On start", icon: "play", tone: "text-slate-600" },
  { id: "onsuccess", label: "On success", icon: "check", tone: "text-emerald-600" },
  { id: "onfailure", label: "On failure", icon: "warning", tone: "text-red-600" },
  {
    id: "onretry",
    label: "On retryable failure",
    icon: "refresh",
    tone: "text-amber-600",
    help: "Fires when a step fails but has retries left.",
  },
  {
    id: "onoverrun",
    label: "Ran longer than usual",
    icon: "clock",
    tone: "text-amber-600",
    help: "Fires when the run passes the threshold below. Leave it blank to use this job's own average.",
    threshold: true,
  },
];

/**
 * Who hears about a run, and when.
 *
 * <p>Channels are the workspace's existing Alert Channels — Slack, Teams,
 * Outlook, Gmail, webhook. This screen binds a channel to a moment; it does not
 * configure a channel, because a credential belongs in one place and that place
 * already exists.
 */
export default function JobNotificationsTab({
  notifications,
  channels,
  channelsError,
  onChange,
}) {
  const usable = channels.filter((c) => c.enabled);
  const forTrigger = (id) => notifications.filter((n) => n.trigger === id);

  const add = (trigger) =>
    onChange([
      ...notifications,
      {
        trigger,
        // Prefer a channel that can actually deliver.
        channelId: (usable[0] ?? channels[0])?.id ?? "",
        threshold: "",
        recipients: "",
      },
    ]);

  const update = (index, patch) =>
    onChange(notifications.map((n, i) => (i === index ? { ...n, ...patch } : n)));

  const remove = (index) => onChange(notifications.filter((_, i) => i !== index));

  return (
    <div className="space-y-4">
      {channelsError && (
        <Card className="border-red-200 bg-red-50/40 p-4">
          <div className="flex items-start gap-3 text-sm">
            <span className="mt-0.5 text-red-600">
              <Icon name="warning" size={16} />
            </span>
            <p className="leading-relaxed text-slate-700">
              Could not load alert channels — {channelsError}. This is a platform
              problem, not a configuration one; the rules below will still save.
            </p>
          </div>
        </Card>
      )}

      {!channelsError && channels.length === 0 && (
        <Card className="border-amber-200 bg-amber-50/40 p-4">
          <div className="flex items-start gap-3 text-sm">
            <span className="mt-0.5 text-amber-600">
              <Icon name="warning" size={16} />
            </span>
            <p className="leading-relaxed text-slate-700">
              This workspace has no alert channels yet, so a notification has
              nowhere to go. Add one under{" "}
              <span className="font-medium text-slate-900">Alert Channels</span>{" "}
              first — the rules below will still save.
            </p>
          </div>
        </Card>
      )}

      {!channelsError && channels.length > 0 && usable.length === 0 && (
        // The case that actually bit: channels exist but every one is turned
        // off, so nothing would ever be delivered. Saying "no channels" here
        // would send someone to re-install an integration they already have.
        <Card className="border-amber-200 bg-amber-50/40 p-4">
          <div className="flex items-start gap-3 text-sm">
            <span className="mt-0.5 text-amber-600">
              <Icon name="warning" size={16} />
            </span>
            <p className="leading-relaxed text-slate-700">
              All {channels.length} of this workspace's alert channels are{" "}
              <span className="font-medium text-slate-900">disabled</span>, so
              nothing would be delivered. Enable one under{" "}
              <span className="font-medium text-slate-900">Alert Channels</span> —
              you can still choose it below.
            </p>
          </div>
        </Card>
      )}

      {TRIGGERS.map((t) => {
        const rules = notifications
          .map((n, i) => ({ ...n, index: i }))
          .filter((n) => n.trigger === t.id);
        return (
          <Card key={t.id} className="p-5">
            <div className="flex items-center justify-between">
              <div className="flex items-start gap-3">
                <span className={`mt-0.5 ${t.tone}`}>
                  <Icon name={t.icon} size={17} />
                </span>
                <div>
                  <p className="text-sm font-semibold text-slate-900">{t.label}</p>
                  {t.help && (
                    <p className="mt-0.5 text-xs leading-relaxed text-slate-500">
                      {t.help}
                    </p>
                  )}
                </div>
              </div>
              <div className="flex items-center gap-2">
                {rules.length > 0 && <Chip>{rules.length}</Chip>}
                <SmallButton icon="plus" onClick={() => add(t.id)}>
                  Notify
                </SmallButton>
              </div>
            </div>

            {rules.length > 0 && (
              <div className="mt-4 space-y-3 border-t border-slate-100 pt-4">
                {rules.map((rule) => (
                  <div
                    key={rule.index}
                    className="grid items-end gap-3 md:grid-cols-[1fr_1fr_auto]"
                  >
                    <div>
                      <label className={label}>Channel</label>
                      <select
                        value={rule.channelId}
                        onChange={(e) =>
                          update(rule.index, { channelId: e.target.value })
                        }
                        className={inputCls}
                      >
                        {channels.length === 0 && (
                          <option value="">No channels configured</option>
                        )}
                        {channels.map((c) => (
                          <option key={c.id} value={c.id}>
                            {c.name}
                            {c.kind ? ` · ${c.kind}` : ""}
                            {c.enabled ? "" : " — disabled"}
                          </option>
                        ))}
                      </select>
                    </div>

                    {t.threshold ? (
                      <div>
                        <label className={label}>Threshold</label>
                        <input
                          value={rule.threshold || ""}
                          onChange={(e) =>
                            update(rule.index, { threshold: e.target.value })
                          }
                          placeholder="e.g. 15m — blank uses this job's average"
                          className={inputCls}
                        />
                      </div>
                    ) : (
                      <div>
                        <label className={label}>Also email (optional)</label>
                        <input
                          value={rule.recipients || ""}
                          onChange={(e) =>
                            update(rule.index, { recipients: e.target.value })
                          }
                          placeholder="ops@example.com"
                          className={inputCls}
                        />
                      </div>
                    )}

                    {rule.channelId &&
                      channels.find(
                        (c) => String(c.id) === String(rule.channelId),
                      )?.enabled === false && (
                        <p className="col-span-full -mt-1 text-[11px] font-medium text-amber-700">
                          This channel is disabled — the rule saves, but nothing
                          will be sent until it is enabled.
                        </p>
                      )}

                    <button
                      onClick={() => remove(rule.index)}
                      aria-label={`Remove ${t.label} notification`}
                      className="mb-0.5 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-slate-500 transition hover:border-red-500 hover:bg-red-500 hover:text-white"
                    >
                      <Icon name="trash" size={15} />
                    </button>
                  </div>
                ))}
              </div>
            )}
          </Card>
        );
      })}
    </div>
  );
}
