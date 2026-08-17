import React from "react";
import { Link } from "react-router-dom";
import Navbar from "../components/Navbar";
import Footer from "../components/Footer";
import Reveal from "../components/Reveal";
import { SectionHeading, PrimaryButton, GhostButton } from "../components/ui";

const TIERS = [
  {
    name: "Starter",
    price: "$49",
    unit: "/ month",
    note: "Starter tier for single-use deployments and pilot workloads.",
    features: [
      "100 Automations / month",
      "25 Jobs",
      "10 Nodes",
      "5 Projects",
      "30 days history",
      '"Powered by AutoOps" badge',
    ],
    cta: "Get started",
    highlight: false,
  },
  {
    name: "Team",
    price: "$99",
    unit: "/ month",
    note: "Best for growing teams running production support use cases.",
    features: [
      "500 Automations / month",
      "100 Jobs",
      "50 Nodes",
      "25 Projects",
      "90 days history",
      '"Powered by AutoOps" badge',
    ],
    cta: "Get started",
    highlight: false,
  },
  {
    name: "Business",
    price: "$199",
    unit: "/ month",
    note: "Advanced automation for enterprise teams handling multimodal workloads.",
    features: [
      "2,000 Automations / month",
      "Unlimited Jobs",
      "500 Nodes",
      "Multimodal & 25 Projects",
      "180 days history",
      "Advanced RBAC",
      '"Powered by AutoOps" badge',
    ],
    cta: "Get started",
    highlight: true,
  },
  {
    name: "Enterprise",
    price: "$399",
    unit: "/ month",
    note: "High-performance plan for scaled operations and advanced AI workloads.",
    features: [
      "Unlimited Automations / month",
      "Unlimited Jobs",
      "Unlimited Nodes",
      "Unlimited Projects",
      "2 years history",
      "Enterprise SSO",
      "White-label (remove AutoOps branding)",
    ],
    cta: "Get started",
    highlight: false,
  },
];

function Tier({ t, i }) {
  return (
    <Reveal delay={(i % 4) * 80}>
      <div
        className={`relative flex h-full flex-col rounded-2xl border p-7 transition duration-300 hover:-translate-y-1.5 ${
          t.highlight
            ? "border-slate-300 bg-gradient-to-b from-slate-200 to-transparent shadow-xl shadow-slate-300/40"
            : "border-slate-200 bg-slate-50 hover:border-blue-500"
        }`}
      >
        {t.highlight && (
          <span className="absolute -top-3 left-1/2 -translate-x-1/2 whitespace-nowrap rounded-full bg-gradient-to-r from-slate-900 to-slate-900 px-3 py-1 text-[11px] font-bold text-white">
            MOST POPULAR
          </span>
        )}
        <h3 className="text-lg font-semibold text-slate-900">{t.name}</h3>
        <div className="mt-4 flex items-end gap-1">
          <span className="text-4xl font-extrabold text-slate-900">
            {t.price}
          </span>
          <span className="pb-1 text-sm text-slate-500">{t.unit}</span>
        </div>
        <p className="mt-3 min-h-[48px] text-xs leading-relaxed text-slate-500">
          {t.note}
        </p>
        <ul className="mt-6 flex-1 space-y-3 text-sm text-slate-600">
          {t.features.map((f) => (
            <li key={f} className="flex items-start gap-2">
              <span className="mt-0.5 text-emerald-600">✓</span>
              <span>{f}</span>
            </li>
          ))}
        </ul>
        <div className="mt-7">
          {t.highlight ? (
            <PrimaryButton to={`/signup?plan=${t.name}`} className="w-full">
              {t.cta} →
            </PrimaryButton>
          ) : (
            <GhostButton to={`/signup?plan=${t.name}`} className="w-full">
              {t.cta} →
            </GhostButton>
          )}
        </div>
      </div>
    </Reveal>
  );
}

export default function Pricing() {
  return (
    <div className="min-h-screen bg-white text-slate-700">
      <Navbar />
      <main className="grid-bg">
        <section className="mx-auto max-w-7xl px-6 py-24">
          <Reveal>
            <SectionHeading
              eyebrow="Pricing"
              title="Plans that scale with your operations"
              subtitle="Start small and grow into full multi-tenant, enterprise-grade automation. Every tier includes the complete AutoOps engine."
            />
          </Reveal>
          <div className="mt-16 grid gap-6 md:grid-cols-2 lg:grid-cols-4">
            {TIERS.map((t, i) => (
              <Tier key={t.name} t={t} i={i} />
            ))}
          </div>
          <p className="mt-10 text-center text-xs text-slate-500">
            All prices in USD. Need something custom?{" "}
            <Link to="/demo" className="text-slate-900 hover:text-blue-600 hover:underline">
              Talk to sales
            </Link>
            .
          </p>
        </section>
      </main>
      <Footer />
    </div>
  );
}
