import React, { useState, useRef, useEffect } from "react";
import { Link } from "react-router-dom";
import Icon from "./Icon";

const TONE = {
  cyan: "bg-slate-100 text-slate-900",
  emerald: "bg-emerald-400/10 text-emerald-600",
  amber: "bg-amber-400/10 text-amber-600",
  red: "bg-red-400/10 text-red-600",
  violet: "bg-violet-400/10 text-violet-600",
};

export default function NotificationsMenu({
  items = [],
  viewAllTo = "#",
  accent = "cyan",
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    const h = (e) => {
      if (ref.current && !ref.current.contains(e.target)) setOpen(false);
    };
    document.addEventListener("mousedown", h);
    return () => document.removeEventListener("mousedown", h);
  }, []);
  const unread = items.filter((n) => !n.read).length;
  const dot = "bg-emerald-400";
  const linkColor = accent === "violet" ? "text-violet-600" : "text-slate-900";
  return (
    <div className="relative" ref={ref}>
      <button
        onClick={() => setOpen((v) => !v)}
        className="relative text-slate-500 transition hover:text-slate-900"
        aria-label="Notifications"
      >
        <Icon name="bell" size={20} />
        {unread > 0 && (
          <span className="absolute -right-0.5 -top-0.5 h-2.5 w-2.5 animate-pulse-dot rounded-full bg-emerald-400 ring-2 ring-white" />
        )}
      </button>
      {open && (
        <div className="absolute right-0 mt-2 w-80 origin-top-right overflow-hidden rounded-xl border border-slate-200 bg-[#ffffff] shadow-2xl shadow-slate-300/40">
          <div className="flex items-center justify-between border-b border-slate-200 px-4 py-3">
            <span className="text-sm font-semibold text-slate-900">
              Notifications
            </span>
            {unread > 0 && (
              <span className="rounded-full bg-slate-50 px-2 py-0.5 text-[11px] text-slate-600">
                {unread} new
              </span>
            )}
          </div>
          <div className="no-scrollbar max-h-80 overflow-y-auto">
            {items.length === 0 && (
              <p className="px-4 py-8 text-center text-sm text-slate-500">
                You’re all caught up.
              </p>
            )}
            {items.slice(0, 6).map((n) => (
              <Link
                key={n.id}
                to={n.link || viewAllTo}
                onClick={() => setOpen(false)}
                className="flex gap-3 border-b border-slate-200 px-4 py-3 transition last:border-0 hover:bg-slate-100"
              >
                <span
                  className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-lg ${TONE[n.tone] || TONE.cyan}`}
                >
                  <Icon name={n.icon || "bell"} size={14} />
                </span>
                <div className="min-w-0 flex-1">
                  <p
                    className={`truncate text-sm ${n.read ? "text-slate-500" : "font-medium text-slate-900"}`}
                  >
                    {n.title}
                  </p>
                  <p className="mt-0.5 text-[11px] text-slate-500">
                    {n.channel === "provider" ? "AutoOps" : "Internal"} ·{" "}
                    {n.time}
                  </p>
                </div>
                {!n.read && (
                  <span
                    className={`mt-1 h-2 w-2 shrink-0 rounded-full ${dot}`}
                  />
                )}
              </Link>
            ))}
          </div>
          <Link
            to={viewAllTo}
            onClick={() => setOpen(false)}
            className={`block border-t border-slate-200 px-4 py-2.5 text-center text-sm font-medium ${linkColor} transition hover:bg-slate-100`}
          >
            View all notifications
          </Link>
        </div>
      )}
    </div>
  );
}
