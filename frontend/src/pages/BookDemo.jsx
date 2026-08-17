import React from "react";
import { Link } from "react-router-dom";
import { LogoMark, PrimaryButton } from "../components/ui";
import Icon from "../components/Icon";

export default function BookDemo() {
  return (
    <div className="grid-bg relative min-h-screen bg-white">
      <div className="pointer-events-none absolute inset-0 -z-10">
        <div className="animate-float-glow absolute left-1/2 top-0 h-[420px] w-[620px] rounded-full bg-slate-100 blur-[150px]" />
      </div>

      <header className="absolute inset-x-0 top-0 z-50 flex items-center justify-between px-6 py-6">
        <Link to="/" className="mb-10 flex items-center gap-2.5">
          <LogoMark size={32} />
        </Link>
        <Link
          to="/"
          className="text-sm font-medium text-slate-500 transition hover:text-slate-900"
        >
          Back to home
        </Link>
      </header>

      <div className="mx-auto flex max-w-6xl flex-col items-center justify-center px-6 pt-32 lg:flex-row lg:items-start lg:justify-between lg:gap-16 lg:pt-40">
        <div className="mb-16 w-full max-w-lg lg:mb-0">
          <h1 className="text-4xl font-extrabold tracking-tight text-slate-900 sm:text-5xl">
            See AutoOps in action
          </h1>
          <p className="mt-6 text-lg leading-relaxed text-slate-500">
            Schedule a personalized demo with our engineering team to see how
            AutoOps can streamline your orchestration, secure your runbooks, and
            automate your platform operations.
          </p>

          <ul className="mt-10 space-y-6">
            {[
              {
                icon: "layers",
                title: "Tailored Walkthrough",
                desc: "We'll focus on the use cases that matter to your platform team.",
              },
              {
                icon: "shield",
                title: "Architecture & Security",
                desc: "Deep dive into our execution sandbox, RBAC, and Vault integrations.",
              },
              {
                icon: "zap",
                title: "Pricing & Onboarding",
                desc: "Get a clear picture of deployment options, costs, and rollout strategies.",
              },
            ].map((f, i) => (
              <li key={i} className="flex items-start gap-4">
                <span className="flex h-12 w-12 shrink-0 items-center justify-center rounded-xl bg-slate-100 text-slate-900 ring-1 ring-slate-300">
                  <Icon name={f.icon} size={24} />
                </span>
                <div>
                  <h3 className="text-base font-semibold text-slate-900">
                    {f.title}
                  </h3>
                  <p className="mt-1 text-sm text-slate-500">{f.desc}</p>
                </div>
              </li>
            ))}
          </ul>
        </div>

        <div className="w-full max-w-md animate-fade-up">
          <div className="rounded-2xl border border-slate-200 bg-slate-50 p-8 shadow-2xl shadow-slate-300/40 backdrop-blur-sm">
            <h2 className="text-2xl font-bold text-slate-900">
              Book your demo
            </h2>
            <p className="mt-2 text-sm text-slate-500">
              Fill out the form below and we'll be in touch shortly.
            </p>

            <form
              className="mt-8 space-y-4"
              onSubmit={(e) => e.preventDefault()}
            >
              <div className="grid gap-4 sm:grid-cols-2">
                <div>
                  <label className="mb-1.5 block text-xs font-medium text-slate-500">
                    First name
                  </label>
                  <input
                    required
                    className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                  />
                </div>
                <div>
                  <label className="mb-1.5 block text-xs font-medium text-slate-500">
                    Last name
                  </label>
                  <input
                    required
                    className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                  />
                </div>
              </div>

              <div>
                <label className="mb-1.5 block text-xs font-medium text-slate-500">
                  Work email
                </label>
                <input
                  required
                  type="email"
                  placeholder="you@company.com"
                  className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                />
              </div>

              <div>
                <label className="mb-1.5 block text-xs font-medium text-slate-500">
                  Company name
                </label>
                <input
                  required
                  className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                />
              </div>

              <div>
                <label className="mb-1.5 block text-xs font-medium text-slate-500">
                  What are you looking to achieve?
                </label>
                <textarea
                  rows={3}
                  className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                />
              </div>

              <button
                type="submit"
                className="mt-2 flex w-full items-center justify-center gap-2 rounded-lg bg-slate-900 px-6 py-3 text-sm font-semibold text-white shadow-lg shadow-slate-300/40 transition hover:bg-blue-600 hover:shadow-blue-300/40"
              >
                Request Demo
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
  );
}
