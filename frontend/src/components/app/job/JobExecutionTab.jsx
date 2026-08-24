import React from "react";
import { Card, Chip, SmallButton } from "../appui";
import Icon from "../../Icon";

const inputCls =
  "w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300";
const label = "mb-1.5 block text-xs font-medium text-slate-500";

// Filters that read a step's output and do something with it. `keyvalue` is
// the one that matters most: without a capture there is no way for step 2 to
// use what step 1 printed.
const LOG_FILTERS = [
  {
    id: "keyvalue",
    label: "Capture data",
    help: "Reads KEY=VALUE lines from a step's output and makes them available to later steps as {{data.KEY}}.",
  },
  {
    id: "mask-passwords",
    label: "Mask secrets",
    help: "Replaces values that look like credentials with ****  before the log is stored.",
  },
  {
    id: "json",
    label: "Parse JSON",
    help: "Treats the step's output as JSON and exposes its fields to later steps.",
  },
  {
    id: "quiet",
    label: "Quiet output",
    help: "Keeps the step's output out of the run log. The exit status still decides success.",
  },
  {
    id: "highlight",
    label: "Highlight matches",
    help: "Marks lines matching a pattern so they stand out in the run log.",
  },
];

/**
 * How the run behaves around the steps: time limits, retries, log handling and
 * concurrency.
 *
 * <p>Everything here already exists in the run engine — this screen is where a
 * job author sets it, rather than it being a platform-wide default nobody can
 * see.
 */
export default function JobExecutionTab({ execution, logFilters, onChange, onFiltersChange }) {
  const set = (field, value) => onChange({ ...execution, [field]: value });

  const toggleFilter = (id) =>
    onFiltersChange(
      logFilters.includes(id)
        ? logFilters.filter((f) => f !== id)
        : [...logFilters, id],
    );

  return (
    <div className="space-y-5">
      <Card className="p-6">
        <h3 className="mb-4 text-sm font-semibold text-slate-900">Limits</h3>
        <div className="grid gap-5 md:grid-cols-2">
          <div>
            <label className={label}>Step timeout (seconds)</label>
            <input
              type="number"
              min="1"
              value={execution.timeoutSeconds ?? ""}
              onChange={(e) =>
                set("timeoutSeconds", e.target.value ? Number(e.target.value) : null)
              }
              placeholder="platform default"
              className={inputCls}
            />
            <p className="mt-1 text-[11px] leading-relaxed text-slate-500">
              A step past this is <strong>stopped</strong>, not abandoned. Capped by
              the platform ceiling, so a larger number here cannot exceed it.
            </p>
          </div>
          <div>
            <label className={label}>Retries per step</label>
            <div className="grid grid-cols-2 gap-3">
              <input
                type="number"
                min="0"
                max="10"
                value={execution.retries ?? 0}
                onChange={(e) => set("retries", Number(e.target.value) || 0)}
                className={inputCls}
              />
              <input
                type="number"
                min="0"
                value={execution.retryDelaySeconds ?? 0}
                onChange={(e) =>
                  set("retryDelaySeconds", Number(e.target.value) || 0)
                }
                placeholder="delay (s)"
                className={inputCls}
              />
            </div>
            <p className="mt-1 text-[11px] leading-relaxed text-slate-500">
              Retrying suits a flaky network call. It does <strong>not</strong> suit
              a step that changes state — that one runs twice.
            </p>
          </div>
        </div>
      </Card>

      <Card className="p-6">
        <h3 className="mb-4 text-sm font-semibold text-slate-900">Run log</h3>
        <div className="grid gap-5 md:grid-cols-2">
          <div>
            <label className={label}>Log level</label>
            <select
              value={execution.logLevel || "INFO"}
              onChange={(e) => set("logLevel", e.target.value)}
              className={inputCls}
            >
              <option value="ERROR">Error</option>
              <option value="WARN">Warning</option>
              <option value="INFO">Info</option>
              <option value="VERBOSE">Verbose</option>
              <option value="DEBUG">Debug</option>
            </select>
            {["DEBUG", "VERBOSE"].includes(execution.logLevel) && (
              // Worth saying plainly: debug logging on a step that was given
              // cloud credentials can put them in the run log.
              <p className="mt-1 text-[11px] font-medium leading-relaxed text-amber-700">
                Debug and verbose logging can record values a step was given,
                including credentials. Use it to diagnose, then turn it back down.
              </p>
            )}
          </div>
          <div>
            <label className={label}>Output limit</label>
            <div className="grid grid-cols-2 gap-3">
              <input
                type="number"
                min="1"
                value={execution.logLimit ?? ""}
                onChange={(e) =>
                  set("logLimit", e.target.value ? Number(e.target.value) : null)
                }
                placeholder="lines"
                className={inputCls}
              />
              <select
                value={execution.logLimitAction || "halt"}
                onChange={(e) => set("logLimitAction", e.target.value)}
                className={inputCls}
              >
                <option value="halt">Stop the run</option>
                <option value="truncate">Keep going, truncate</option>
              </select>
            </div>
            <p className="mt-1 text-[11px] text-slate-500">
              Blank uses the platform cap.
            </p>
          </div>
        </div>

        <div className="mt-6 border-t border-slate-100 pt-5">
          <p className="mb-1 text-xs font-semibold text-slate-700">Output filters</p>
          <p className="mb-3 text-[11px] leading-relaxed text-slate-500">
            Applied to every step's output as it is produced.
          </p>
          <div className="space-y-2">
            {LOG_FILTERS.map((f) => (
              <label
                key={f.id}
                className="flex cursor-pointer items-start gap-3 rounded-lg border border-slate-200 bg-slate-50 p-3 transition hover:border-slate-300"
              >
                <input
                  type="checkbox"
                  checked={logFilters.includes(f.id)}
                  onChange={() => toggleFilter(f.id)}
                  className="mt-0.5 h-4 w-4 rounded accent-blue-600"
                />
                <span className="min-w-0">
                  <span className="text-sm font-medium text-slate-900">
                    {f.label}
                  </span>
                  <span className="mt-0.5 block text-[11px] leading-relaxed text-slate-500">
                    {f.help}
                  </span>
                </span>
              </label>
            ))}
          </div>
        </div>
      </Card>

      <Card className="p-6">
        <h3 className="mb-4 text-sm font-semibold text-slate-900">Concurrency</h3>
        <label className="flex cursor-pointer items-start gap-3">
          <input
            type="checkbox"
            checked={!!execution.multipleExecutions}
            onChange={(e) => set("multipleExecutions", e.target.checked)}
            className="mt-0.5 h-4 w-4 rounded accent-blue-600"
          />
          <span>
            <span className="text-sm font-medium text-slate-900">
              Allow simultaneous runs
            </span>
            <span className="mt-1 block text-[11px] leading-relaxed text-slate-500">
              Off by default, and that default is the safe one: a scheduled job
              that overruns its interval would otherwise start again while the
              first run is still changing the same things.
            </span>
          </span>
        </label>
      </Card>
    </div>
  );
}
