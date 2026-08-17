import React, { useState } from "react";
import { Card } from "./appui";
import {
  THROUGHPUT_RANGES,
  DEFAULT_RANGE,
  buildThroughput,
} from "../../lib/throughput";

// Stacked execution-throughput bars. Every page that showed this chart had its
// own copy of the markup — and two of them fed it a hardcoded empty array, so
// the card was permanently blank. One component, one data path.

const LEGEND = [
  { label: "Success", dot: "bg-emerald-400" },
  { label: "Failed", dot: "bg-red-400" },
  { label: "Running", dot: "bg-blue-400" },
];

export default function ThroughputChart({
  executions = [],
  loading = false,
  defaultRange = DEFAULT_RANGE,
  showRangeSelect = true,
  title = "Execution throughput",
  height = "h-44",
  className = "p-6",
}) {
  const [rangeKey, setRangeKey] = useState(defaultRange);
  const buckets = buildThroughput(executions, rangeKey);
  // Scale to the busiest bucket so a single run still draws a visible bar.
  const max = Math.max(1, ...buckets.map((b) => b.total));
  const isEmpty = buckets.every((b) => b.total === 0);
  const rangeLabel =
    THROUGHPUT_RANGES.find((r) => r.key === rangeKey)?.label || "";

  return (
    <Card className={className}>
      <div className="mb-5 flex items-center justify-between">
        <div className="flex items-center gap-4">
          <h3 className="text-sm font-semibold text-slate-900">{title}</h3>
          <div className="hidden items-center gap-3 text-xs text-slate-500 sm:flex">
            {LEGEND.map((l) => (
              <span key={l.label} className="flex items-center gap-1.5">
                <span className={`h-2 w-2 rounded-full ${l.dot}`} />
                {l.label}
              </span>
            ))}
          </div>
        </div>
        {showRangeSelect ? (
          <select
            value={rangeKey}
            onChange={(e) => setRangeKey(e.target.value)}
            aria-label="Throughput time range"
            className="cursor-pointer bg-transparent text-xs font-medium text-slate-500 outline-none hover:text-slate-900"
          >
            {THROUGHPUT_RANGES.map((r) => (
              <option key={r.key} value={r.key}>
                {r.label}
              </option>
            ))}
          </select>
        ) : (
          <span className="text-xs font-medium text-slate-500">
            {rangeLabel}
          </span>
        )}
      </div>

      <div className={`relative flex ${height} items-end gap-1`}>
        {(loading || isEmpty) && (
          <p className="pointer-events-none absolute inset-0 flex items-center justify-center text-xs text-slate-500">
            {loading
              ? "Loading executions…"
              : `No executions in the ${rangeLabel.toLowerCase()}.`}
          </p>
        )}
        {buckets.map((b, i) => {
          const bar = (b.total / max) * 100;
          const success = b.total ? (b.success / b.total) * bar : 0;
          const failed = b.total ? (b.failed / b.total) * bar : 0;
          const running = b.total ? (b.running / b.total) * bar : 0;
          return (
            <div
              key={i}
              className="group relative flex h-full flex-1 flex-col justify-end gap-[1px]"
            >
              {b.total > 0 && (
                <div className="pointer-events-none absolute bottom-full left-1/2 z-20 mb-2 flex -translate-x-1/2 flex-col gap-1.5 whitespace-nowrap rounded-lg bg-slate-900 px-3 py-2 text-xs text-white opacity-0 shadow-xl transition-opacity duration-200 group-hover:opacity-100">
                  <div className="mb-0.5 border-b border-slate-700 pb-1.5 font-semibold text-slate-300">
                    {b.label} · {b.total} execution{b.total === 1 ? "" : "s"}
                  </div>
                  <div className="flex items-center justify-between gap-4">
                    <span className="flex items-center gap-1.5">
                      <span className="h-1.5 w-1.5 rounded-full bg-emerald-400" />
                      Success
                    </span>
                    <span className="font-mono font-medium">{b.success}</span>
                  </div>
                  <div className="flex items-center justify-between gap-4">
                    <span className="flex items-center gap-1.5">
                      <span className="h-1.5 w-1.5 rounded-full bg-red-400" />
                      Failed
                    </span>
                    <span className="font-mono font-medium">{b.failed}</span>
                  </div>
                  <div className="flex items-center justify-between gap-4">
                    <span className="flex items-center gap-1.5">
                      <span className="h-1.5 w-1.5 rounded-full bg-blue-400" />
                      Running
                    </span>
                    <span className="font-mono font-medium">{b.running}</span>
                  </div>
                  <div className="absolute left-1/2 top-full -translate-x-1/2 border-4 border-transparent border-t-slate-900" />
                </div>
              )}

              <div
                className="w-full animate-fade-up rounded-t-sm bg-blue-400/80 transition-all duration-300 group-hover:bg-blue-500"
                style={{
                  height: `${running}%`,
                  animationDelay: `${i * 0.04}s`,
                }}
              />
              <div
                className="w-full animate-fade-up bg-red-400/80 transition-all duration-300 group-hover:bg-red-500"
                style={{ height: `${failed}%`, animationDelay: `${i * 0.04}s` }}
              />
              <div
                className="w-full animate-fade-up rounded-b-sm bg-emerald-400/80 transition-all duration-300 group-hover:bg-emerald-500"
                style={{ height: `${success}%`, animationDelay: `${i * 0.04}s` }}
              />
            </div>
          );
        })}
      </div>
    </Card>
  );
}