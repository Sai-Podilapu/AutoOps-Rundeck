import React, { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { useNavigate } from "react-router-dom";
import Icon from "../Icon";

// Titles per gate-denial code (the body text is the backend's own message).
const COPY = {
  feature_not_in_plan: {
    title: "This feature isn't in your plan",
    cta: "View plans",
  },
  quota_exceeded: { title: "You've reached a plan limit", cta: "View plans" },
  trial_expired: { title: "Your trial has ended", cta: "Choose a plan" },
  subscription_expired: {
    title: "Your subscription has expired",
    cta: "Renew subscription",
  },
  subscription_past_due: {
    title: "There's a payment issue",
    cta: "Review billing",
  },
  subscription_canceled: {
    title: "Your subscription was cancelled",
    cta: "Reactivate",
  },
  no_subscription: { title: "Pick a plan to get started", cta: "View plans" },
};

// Global upgrade/renew prompt: api.js dispatches "autoops:upgrade-required"
// whenever the subscription gate denies an action; this modal turns the bare
// 403 into a path to Billing. Mounted once in AppLayout.
export default function UpgradeModal() {
  const [gate, setGate] = useState(null);
  const navigate = useNavigate();

  useEffect(() => {
    const onGate = (e) => setGate(e.detail);
    window.addEventListener("autoops:upgrade-required", onGate);
    return () => window.removeEventListener("autoops:upgrade-required", onGate);
  }, []);

  if (!gate) return null;
  const copy = COPY[gate.code] || COPY.feature_not_in_plan;

  return createPortal(
    <div className="fixed inset-0 z-[120] flex items-center justify-center p-4">
      <div
        className="absolute inset-0 bg-slate-900/25 backdrop-blur-md"
        onClick={() => setGate(null)}
      />
      <div className="relative w-full max-w-md animate-fade-up rounded-2xl border border-slate-200 bg-white p-6 shadow-2xl">
        <div className="flex items-start gap-4">
          <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-slate-100 text-slate-900">
            <Icon name="lock" size={22} />
          </span>
          <div className="min-w-0">
            <h2 className="text-base font-semibold text-slate-900">
              {copy.title}
            </h2>
            <p className="mt-1.5 text-sm text-slate-600">{gate.message}</p>
          </div>
        </div>
        <div className="mt-6 flex justify-end gap-3">
          <button
            onClick={() => setGate(null)}
            className="rounded-lg border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-900 transition hover:bg-slate-100"
          >
            Not now
          </button>
          <button
            onClick={() => {
              setGate(null);
              navigate("/app/billing");
            }}
            className="inline-flex items-center gap-1.5 rounded-lg bg-slate-900 px-4 py-2 text-sm font-semibold text-white transition hover:bg-slate-700"
          >
            <Icon name="scale" size={16} /> {copy.cta}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
