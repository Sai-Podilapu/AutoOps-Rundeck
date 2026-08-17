import React, { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { PageHeader, Card } from "../../components/app/appui";
import Icon from "../../components/Icon";
import { notificationFilters } from "../../data/saasData";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";

const TONE = {
  cyan: "bg-slate-100 text-slate-900",
  emerald: "bg-emerald-400/10 text-emerald-600",
  amber: "bg-amber-400/10 text-amber-600",
  red: "bg-red-400/10 text-red-600",
  violet: "bg-violet-400/10 text-violet-600",
};

const KIND_TONE = { PROVIDER: "violet", ALERT: "red", SYSTEM: "cyan" };

function timeAgo(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "";
  const s = Math.floor((Date.now() - d.getTime()) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

function mapNotification(n) {
  const kind = String(n.kind || "SYSTEM").toUpperCase();
  return {
    id: n.id,
    title: n.title,
    body: n.body,
    read: !!n.read,
    channel: kind === "PROVIDER" ? "provider" : "internal",
    category:
      kind === "PROVIDER" ? "AutoOps" : kind === "ALERT" ? "Alert" : "System",
    tone: KIND_TONE[kind] || "cyan",
    icon: kind === "ALERT" ? "shield" : "bell",
    time: timeAgo(n.createdAt),
    link: n.link || "#",
  };
}

export default function Notifications() {
  const { pushToast } = useStore();
  const [items, setItems] = useState([]);
  const [filter, setFilter] = useState("All");

  const load = async () => {
    try {
      const data = await api.listNotifications();
      const list = Array.isArray(data) ? data : data?.items || [];
      setItems(list.map(mapNotification));
    } catch (e) {
      // Honest empty state — never seed fake notifications.
      setItems([]);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const shown = items.filter((n) =>
    filter === "All"
      ? true
      : filter === "Unread"
        ? !n.read
        : filter === "Provider"
          ? n.channel === "provider"
          : n.channel === "internal",
  );
  const unread = items.filter((n) => !n.read).length;

  const markAll = async () => {
    setItems((a) => a.map((n) => ({ ...n, read: true })));
    try {
      await api.markAllNotificationsRead();
      pushToast("All notifications marked as read", "emerald");
    } catch (e) {
      pushToast(e.message || "Could not mark all as read", "red");
    }
  };

  const openOne = async (id) => {
    setItems((a) => a.map((n) => (n.id === id ? { ...n, read: true } : n)));
    try {
      await api.markNotificationRead(id);
    } catch (e) {
      /* non-blocking */
    }
  };

  return (
    <div className="mx-auto max-w-4xl animate-fade-up">
      <PageHeader
        title="Notifications"
        subtitle={`${unread} unread · provider broadcasts and your internal alerts`}
        actions={
          <button
            onClick={markAll}
            className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3.5 py-2 text-sm font-semibold text-slate-900 transition hover:border-blue-500 hover:bg-slate-100"
          >
            <Icon name="check" size={16} /> Mark all read
          </button>
        }
      />
      <div className="mb-5 flex flex-wrap gap-2">
        {notificationFilters.map((f) => (
          <button
            key={f}
            onClick={() => setFilter(f)}
            className={`rounded-full border px-3.5 py-1.5 text-sm transition ${filter === f ? "border-slate-300 bg-slate-100 text-slate-900" : "border-slate-200 text-slate-500 hover:text-slate-900"}`}
          >
            {f}
          </button>
        ))}
      </div>
      <div className="space-y-2.5">
        {shown.map((n) => (
          <Link
            key={n.id}
            to={n.link || "#"}
            onClick={() => openOne(n.id)}
            className={`flex gap-4 rounded-xl border p-4 transition ${n.read ? "border-slate-200 bg-slate-50" : "border-slate-200 bg-slate-50"} hover:border-blue-500`}
          >
            <span
              className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-lg ${TONE[n.tone] || TONE.cyan}`}
            >
              <Icon name={n.icon || "bell"} size={18} />
            </span>
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-2">
                <span
                  className={`rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${n.channel === "provider" ? "bg-violet-400/10 text-violet-600" : "bg-slate-400/10 text-slate-600"}`}
                >
                  {n.channel === "provider" ? "AutoOps" : "Internal"}
                </span>
                <span className="text-[11px] text-slate-500">
                  {n.category} · {n.time}
                </span>
                {!n.read && (
                  <span className="ml-auto h-2 w-2 rounded-full bg-slate-100" />
                )}
              </div>
              <p
                className={`mt-1.5 text-sm ${n.read ? "text-slate-600" : "font-semibold text-slate-900"}`}
              >
                {n.title}
              </p>
              <p className="mt-1 text-sm text-slate-500">{n.body}</p>
            </div>
          </Link>
        ))}
        {shown.length === 0 && (
          <Card className="p-10">
            <p className="text-center text-sm text-slate-500">
              Nothing here yet.
            </p>
          </Card>
        )}
      </div>
    </div>
  );
}
