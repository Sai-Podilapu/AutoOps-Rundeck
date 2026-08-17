import React from "react";
import Reveal from "../components/Reveal";
import { Pill } from "../components/ui";

const BARS = [42, 65, 38, 80, 55, 72, 60, 90, 48, 68, 75, 58];
const LOG = [
  { t: "12:04:21", m: "execution #4821 started", c: "text-slate-500" },
  { t: "12:04:22", m: "node web-01 ✓ healthy", c: "text-emerald-600" },
  { t: "12:04:25", m: "node web-02 ✓ healthy", c: "text-emerald-600" },
  { t: "12:04:31", m: "deploy succeeded in 9.2s", c: "text-slate-900" },
];

export default function Observability() {
  return (
    <section className="mx-auto max-w-7xl px-6 py-24">
      <div className="grid items-center gap-12 lg:grid-cols-2">
        <Reveal repeat={true} className="order-2 lg:order-1">
          <div className="space-y-4">
            <div className="grid grid-cols-3 gap-4">
              {[
                { k: "Success rate", v: "99.2%", c: "text-emerald-600" },
                { k: "Avg duration", v: "9.4s", c: "text-slate-900" },
                { k: "Runs today", v: "1,284", c: "text-slate-900" },
              ].map((kpi) => (
                <div
                  key={kpi.k}
                  className="rounded-xl border border-slate-200 bg-slate-50 p-4"
                >
                  <p className="text-[11px] text-slate-500">{kpi.k}</p>
                  <p className={`mt-1 text-xl font-bold ${kpi.c}`}>{kpi.v}</p>
                </div>
              ))}
            </div>
            <div className="rounded-xl border border-slate-200 bg-slate-50 p-5">
              <div className="mb-5 flex items-center justify-between">
                <div className="flex items-center gap-4">
                  <h3 className="text-sm font-semibold text-slate-900">
                    Execution throughput
                  </h3>
                  <div className="hidden items-center gap-3 text-xs text-slate-500 sm:flex">
                    <span className="flex items-center gap-1.5">
                      <span className="h-2 w-2 rounded-full bg-emerald-400"></span>
                      Success
                    </span>
                    <span className="flex items-center gap-1.5">
                      <span className="h-2 w-2 rounded-full bg-red-400"></span>
                      Failed
                    </span>
                    <span className="flex items-center gap-1.5">
                      <span className="h-2 w-2 rounded-full bg-blue-400"></span>
                      Running
                    </span>
                  </div>
                </div>
                <select className="bg-transparent text-xs font-medium text-slate-500 outline-none hover:text-slate-900 cursor-pointer">
                  <option>Last 15 min</option>
                  <option>Last 1 hour</option>
                  <option>Yesterday</option>
                  <option>Last 7 days</option>
                  <option>Last 30 days</option>
                </select>
              </div>
              <div className="flex h-44 items-end gap-1">
                {BARS.map((h, i) => {
                  const success = h * 0.75 + (i % 2) * 2;
                  const failed = h * 0.1 + (i % 3) * 1;
                  const running = h - success - failed;
                  return (
                    <div key={i} className="group relative flex h-full flex-1 flex-col justify-end gap-[1px]">
                      {/* Custom Tooltip */}
                      <div className="pointer-events-none absolute bottom-full left-1/2 z-20 mb-2 -translate-x-1/2 opacity-0 transition-opacity duration-200 group-hover:opacity-100 flex flex-col gap-1.5 rounded-lg bg-slate-900 px-3 py-2 text-xs text-white shadow-xl whitespace-nowrap">
                        <div className="font-semibold text-slate-300 border-b border-slate-700 pb-1.5 mb-0.5">Total Executions: {Math.round(h)}</div>
                        <div className="flex items-center justify-between gap-4">
                          <span className="flex items-center gap-1.5"><span className="h-1.5 w-1.5 rounded-full bg-emerald-400"></span>Success</span>
                          <span className="font-mono font-medium">{Math.round(success)}</span>
                        </div>
                        <div className="flex items-center justify-between gap-4">
                          <span className="flex items-center gap-1.5"><span className="h-1.5 w-1.5 rounded-full bg-red-400"></span>Failed</span>
                          <span className="font-mono font-medium">{Math.round(failed)}</span>
                        </div>
                        <div className="flex items-center justify-between gap-4">
                          <span className="flex items-center gap-1.5"><span className="h-1.5 w-1.5 rounded-full bg-blue-400"></span>Running</span>
                          <span className="font-mono font-medium">{Math.round(running)}</span>
                        </div>
                        <div className="absolute left-1/2 top-full -translate-x-1/2 border-4 border-transparent border-t-slate-900" />
                      </div>

                      <div
                        className="w-full rounded-t-sm bg-blue-400/80 transition-all duration-300 group-hover:bg-blue-500 animate-fade-up"
                        style={{ height: `${running}%`, animationDelay: `${i * 0.04}s` }}
                      />
                      <div
                        className="w-full bg-red-400/80 transition-all duration-300 group-hover:bg-red-500 animate-fade-up"
                        style={{ height: `${failed}%`, animationDelay: `${i * 0.04}s` }}
                      />
                      <div
                        className="w-full rounded-b-sm bg-emerald-400/80 transition-all duration-300 group-hover:bg-emerald-500 animate-fade-up"
                        style={{ height: `${success}%`, animationDelay: `${i * 0.04}s` }}
                      />
                    </div>
                  );
                })}
              </div>
            </div>
            <div className="rounded-xl border border-slate-200 bg-slate-900/30 p-4 font-mono text-xs">
              {LOG.map((l, i) => (
                <div key={i} className="flex gap-3 py-0.5">
                  <span className="text-slate-600">{l.t}</span>
                  <span className={l.c}>{l.m}</span>
                </div>
              ))}
            </div>
          </div>
        </Reveal>

        <Reveal delay={120} className="order-1 lg:order-2">
          <Pill>Observability</Pill>
          <h2 className="mt-5 text-4xl font-bold leading-tight tracking-tight text-slate-900 sm:text-5xl">
            See every run as it happens
          </h2>
          <p className="mt-5 max-w-md text-base leading-relaxed text-slate-500">
            Real-time dashboards, throughput and success/failure charts, live
            log streaming, and an in-browser console terminal give your team
            complete visibility into every job, node, and execution.
          </p>
          <ul className="mt-6 space-y-3 text-sm text-slate-600">
            {[
              "Live logs over SSE & WebSocket",
              "Per-node health and environment discovery",
              "xterm-based admin console in the browser",
            ].map((t) => (
              <li key={t} className="flex items-start gap-2">
                <span className="mt-0.5 text-emerald-600">✓</span> {t}
              </li>
            ))}
          </ul>
        </Reveal>
      </div>
    </section>
  );
}
