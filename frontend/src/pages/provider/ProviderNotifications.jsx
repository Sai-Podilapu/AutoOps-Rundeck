import React, { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { PageHeader, Card, Pagination } from "../../components/app/appui";
import Icon from "../../components/Icon";
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
    category:
      kind === "PROVIDER" ? "Platform" : kind === "ALERT" ? "Alert" : "System",
    tone: KIND_TONE[kind] || "violet",
    icon: kind === "ALERT" ? "shield" : "bell",
    time: timeAgo(n.createdAt),
    link: n.link || "#",
  };
}

export default function ProviderNotifications() {
  const { pushToast } = useStore();
  const [items, setItems] = useState([]);
  const [error, setError] = useState(null);
  const [page, setPage] = useState(1);
  const pageSize = 5;

  const load = async () => {
    setError(null);
    try {
      const data = await api.listNotifications();
      const list = Array.isArray(data) ? data : data?.items || [];
      setItems(list.map(mapNotification));
    } catch (e) {
      setItems([]);
      setError(e.message || "Could not load notifications");
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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

  const totalPages = Math.ceil(items.length / pageSize) || 1;
  const currentPage = Math.min(page, totalPages);
  const visibleItems = items.slice((currentPage - 1) * pageSize, currentPage * pageSize);

  return (
    <div className="mx-auto max-w-4xl animate-fade-up">
      <PageHeader
        title="Notifications"
        subtitle={`${unread} unread · platform and business alerts`}
        actions={
          <button
            onClick={markAll}
            className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3.5 py-2 text-sm font-semibold text-slate-900 transition hover:border-blue-500 hover:bg-slate-100"
          >
            <Icon name="check" size={16} /> Mark all read
          </button>
        }
      />
      <div className="space-y-2.5">
        {visibleItems.map((n) => (
          <Link
            key={n.id}
            to={n.link || "#"}
            onClick={() => openOne(n.id)}
            className={`flex gap-4 rounded-xl border p-4 transition ${n.read ? "border-slate-200 bg-slate-50" : "border-slate-200 bg-slate-50"} hover:border-violet-400/30`}
          >
            <span
              className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-lg ${TONE[n.tone] || TONE.violet}`}
            >
              <Icon name={n.icon || "bell"} size={18} />
            </span>
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-2">
                <span className="rounded-full bg-violet-400/10 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-violet-600">
                  {n.category}
                </span>
                <span className="text-[11px] text-slate-500">{n.time}</span>
                {!n.read && (
                  <span className="ml-auto h-2 w-2 rounded-full bg-violet-400" />
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
        {items.length === 0 && (
          <Card className="p-10">
            {error ? (
              <p className="text-center text-sm text-red-600">
                {error}{" "}
                <button
                  onClick={load}
                  className="ml-1 text-slate-900 underline"
                >
                  Try again
                </button>
              </p>
            ) : (
              <p className="text-center text-sm text-slate-500">
                No notifications yet.
              </p>
            )}
          </Card>
        )}
        <Pagination page={currentPage} pageSize={pageSize} totalItems={items.length} onPageChange={setPage} />
      </div>
    </div>
  );
}
