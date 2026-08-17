import React, { useState } from "react";
import { PageHeader, Card } from "../../components/app/appui";
import Icon from "../../components/Icon";
import { useStore } from "../../store/store";
import { api } from "../../lib/api";

export default function Broadcasts() {
  const { pushToast } = useStore();
  const [title, setTitle] = useState("");
  const [message, setMessage] = useState("");
  const [link, setLink] = useState("");
  const [busy, setBusy] = useState(false);
  // Broadcasts sent during this session (the backend does not expose a
  // broadcast history endpoint).
  const [sent, setSent] = useState([]);

  const submit = async () => {
    if (!title.trim()) {
      pushToast("Add a title first", "red");
      return;
    }
    if (!message.trim()) {
      pushToast("Add a message first", "red");
      return;
    }
    setBusy(true);
    try {
      const res = await api.createBroadcast({
        title: title.trim(),
        body: message.trim(),
        link: link.trim() || undefined,
      });
      const count = Number(res?.sent ?? 0);
      setSent((a) => [
        {
          id: Date.now(),
          title: title.trim(),
          body: message.trim(),
          link: link.trim() || null,
          sent: count,
          at: new Date(),
        },
        ...a,
      ]);
      pushToast(
        `Broadcast sent to ${count} tenant${count === 1 ? "" : "s"}`,
        "violet",
      );
      setTitle("");
      setMessage("");
      setLink("");
    } catch (e) {
      pushToast(e.message || "Failed to send broadcast", "red");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Broadcasts"
        subtitle="Push announcements to every tenant's notification center"
      />

      <div className="grid gap-6 lg:grid-cols-5">
        <Card className="p-5 lg:col-span-2">
          <h3 className="text-sm font-semibold text-slate-900">
            New broadcast
          </h3>
          <p className="mt-1 text-xs text-slate-500">
            Delivered to every tenant's notification center.
          </p>
          <label className="mt-4 block text-xs font-medium text-slate-500">
            Title
          </label>
          <input
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="e.g. New workflow available"
            className="mt-1 w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-900 outline-none focus:border-violet-400/50 focus:ring-2 focus:ring-violet-400/15"
          />
          <label className="mt-3 block text-xs font-medium text-slate-500">
            Message
          </label>
          <textarea
            value={message}
            onChange={(e) => setMessage(e.target.value)}
            rows={3}
            placeholder="What’s changing for your customers?"
            className="mt-1 w-full resize-none rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-900 outline-none focus:border-violet-400/50 focus:ring-2 focus:ring-violet-400/15"
          />
          <label className="mt-3 block text-xs font-medium text-slate-500">
            Link (optional)
          </label>
          <input
            value={link}
            onChange={(e) => setLink(e.target.value)}
            placeholder="e.g. /app/library"
            className="mt-1 w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-900 outline-none focus:border-violet-400/50 focus:ring-2 focus:ring-violet-400/15"
          />
          <p className="mt-3 flex items-center gap-1.5 text-[11px] text-violet-600">
            <Icon name="users" size={13} /> Sent to all tenants
          </p>
          <div className="mt-5">
            <button
              onClick={submit}
              disabled={busy}
              className="inline-flex w-full items-center justify-center gap-1.5 rounded-lg bg-gradient-to-r from-slate-900 to-slate-900 px-4 py-2 text-sm font-semibold text-white transition hover:brightness-110 disabled:opacity-50"
            >
              <Icon name="bell" size={16} />{" "}
              {busy ? "Sending…" : "Send broadcast"}
            </button>
          </div>
        </Card>

        <div className="space-y-4 lg:col-span-3">
          {(title.trim() || message.trim()) && (
            <Card className="p-4">
              <p className="mb-2 text-[11px] font-semibold uppercase tracking-wider text-slate-500">
                Preview — client notification
              </p>
              <div className="flex gap-3 rounded-lg border border-slate-200 bg-slate-50 p-3">
                <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-violet-400/10 text-violet-600">
                  <Icon name="bolt" size={16} />
                </span>
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="rounded-full bg-violet-400/10 px-2 py-0.5 text-[10px] font-semibold uppercase text-violet-600">
                      AutoOps
                    </span>
                    <span className="text-[11px] text-slate-500">just now</span>
                  </div>
                  <p className="mt-1 text-sm font-semibold text-slate-900">
                    {title || "Your title appears here"}
                  </p>
                  <p className="text-sm text-slate-500">
                    {message || "Your message preview appears here."}
                  </p>
                </div>
              </div>
            </Card>
          )}

          <Card className="p-5">
            <h3 className="text-sm font-semibold text-slate-900">
              Sent this session
            </h3>
            {sent.length === 0 ? (
              <p className="mt-3 text-sm text-slate-500">
                No broadcasts sent yet this session.
              </p>
            ) : (
              <div className="mt-3 space-y-3">
                {sent.map((b) => (
                  <div
                    key={b.id}
                    className="flex items-start justify-between gap-3 rounded-lg border border-slate-200 bg-slate-50 p-3"
                  >
                    <div className="min-w-0">
                      <p className="text-sm font-medium text-slate-900">
                        {b.title}
                      </p>
                      <p className="truncate text-xs text-slate-500">
                        {b.body}
                      </p>
                      {b.link && (
                        <p className="mt-0.5 truncate font-mono text-[11px] text-violet-600">
                          {b.link}
                        </p>
                      )}
                    </div>
                    <div className="shrink-0 text-right">
                      <span className="inline-flex items-center gap-1.5 rounded-full border border-emerald-400/30 bg-emerald-400/10 px-2.5 py-0.5 text-xs font-medium text-emerald-600">
                        <span className="h-1.5 w-1.5 rounded-full bg-current" />
                        Sent to {b.sent}
                      </span>
                      <p className="mt-1 text-[11px] text-slate-500">
                        {b.at.toLocaleTimeString()}
                      </p>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </Card>
        </div>
      </div>
    </div>
  );
}
