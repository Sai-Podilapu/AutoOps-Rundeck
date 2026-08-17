import React from "react";
import { Link } from "react-router-dom";
import { Logo, PrimaryButton } from "../components/ui";
import Icon from "../components/Icon";
import Footer from "../components/Footer";
import Navbar from "../components/Navbar";

export default function Docs() {
  const categories = [
    {
      title: "Getting Started",
      icon: "rocket",
      links: [
        "Quickstart Guide",
        "Installation & Setup",
        "Core Concepts",
        "First Workflow",
      ],
    },
    {
      title: "Architecture",
      icon: "layers",
      links: [
        "Execution Engine",
        "Event Bus & Streams",
        "State Management",
        "High Availability",
      ],
    },
    {
      title: "Workflows",
      icon: "blocks",
      links: [
        "DAG Syntax",
        "Triggers & Schedules",
        "Approval Gates",
        "Handling Failures",
      ],
    },
    {
      title: "Security & RBAC",
      icon: "shield",
      links: [
        "Authentication (OIDC)",
        "Role-based Access",
        "Vault Integrations",
        "Audit Logs",
      ],
    },
    {
      title: "Integrations",
      icon: "puzzle",
      links: ["AWS & GCP", "Kubernetes", "Slack & Teams", "Custom Webhooks"],
    },
    {
      title: "API Reference",
      icon: "api",
      links: ["REST API", "Authentication", "Rate Limits", "Websockets"],
    },
  ];

  return (
    <div className="min-h-screen bg-white">
      <Navbar />

      <main className="mx-auto max-w-7xl px-6 py-16 lg:py-24">
        <div className="mb-16 text-center">
          <h1 className="text-4xl font-extrabold tracking-tight text-slate-900 sm:text-5xl">
            Documentation
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-lg text-slate-500">
            Everything you need to deploy, configure, and scale AutoOps. Explore
            our guides, API reference, and architectural deep-dives.
          </p>

          <div className="mx-auto mt-10 max-w-xl relative">
            <Icon
              name="search"
              size={20}
              className="absolute left-4 top-1/2 -translate-y-1/2 text-slate-500"
            />
            <input
              type="text"
              placeholder="Search the docs..."
              className="w-full rounded-xl border border-slate-200 bg-slate-50 py-4 pl-12 pr-4 text-slate-900 outline-none transition focus:border-slate-300 focus:bg-slate-50 focus:ring-2 focus:ring-slate-300"
            />
          </div>
        </div>

        <div className="grid gap-8 md:grid-cols-2 lg:grid-cols-3">
          {categories.map((c, i) => (
            <div
              key={i}
              className="rounded-2xl border border-slate-200 bg-slate-50 p-8 transition hover:border-blue-500 hover:bg-slate-100"
            >
              <div className="flex items-center gap-4">
                <span className="flex h-12 w-12 items-center justify-center rounded-xl bg-slate-100 text-slate-900 ring-1 ring-slate-300">
                  <Icon name={c.icon} size={24} />
                </span>
                <h3 className="text-xl font-bold text-slate-900">{c.title}</h3>
              </div>
              <ul className="mt-6 space-y-3">
                {c.links.map((link) => (
                  <li key={link}>
                    <Link
                      to="#"
                      className="text-sm font-medium text-slate-500 transition hover:text-slate-900"
                    >
                      {link}
                    </Link>
                  </li>
                ))}
              </ul>
              <div className="mt-6 border-t border-slate-200 pt-4">
                <Link
                  to="#"
                  className="text-sm font-semibold text-slate-900 hover:text-slate-900"
                >
                  View all →
                </Link>
              </div>
            </div>
          ))}
        </div>

        <div className="mt-20 rounded-2xl bg-gradient-to-br from-slate-200 to-slate-200 p-8 text-center sm:p-12">
          <h2 className="text-2xl font-bold text-slate-900">
            Can't find what you're looking for?
          </h2>
          <p className="mt-3 text-slate-500">
            Join our community Discord or reach out to enterprise support.
          </p>
          <div className="mt-8 flex flex-col items-center justify-center gap-4 sm:flex-row">
            <PrimaryButton to="/demo">Contact Support</PrimaryButton>
            <Link
              to="#"
              className="text-sm font-semibold text-slate-900 transition hover:text-slate-900"
            >
              Join Community Discord
            </Link>
          </div>
        </div>
      </main>

      <Footer />
    </div>
  );
}
