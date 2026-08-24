import React from "react";
import { Card } from "../appui";
import Icon from "../../Icon";
import { timezoneOptions } from "../../../lib/timezones";

const inputCls =
  "w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300";
const label = "mb-1.5 block text-xs font-medium text-slate-500";

// Everyday schedules, so the common case never needs cron syntax.
const PRESETS = [
  { label: "Every 15 minutes", cron: "0 */15 * * * *" },
  { label: "Hourly", cron: "0 0 * * * *" },
  { label: "Daily at 02:00", cron: "0 0 2 * * *" },
  { label: "Weekdays at 08:00", cron: "0 0 8 * * MON-FRI" },
  { label: "Weekly, Sunday 03:00", cron: "0 0 3 * * SUN" },
  { label: "Monthly, 1st at 04:00", cron: "0 0 4 1 * *" },
];

/**
 * When the job runs by itself.
 *
 * <p>The timezone is stored with the schedule rather than assumed. A job that
 * runs "at 02:00" means 02:00 somewhere, and getting that wrong moves a
 * maintenance window into the middle of a working day twice a year.
 */
export default function JobScheduleTab({ schedule, timezone, onChange }) {
  const enabled = !!schedule;

  return (
    <div className="space-y-5">
      <Card className="p-6">
        <label className="flex cursor-pointer items-start gap-3">
          <input
            type="checkbox"
            checked={enabled}
            onChange={(e) =>
              onChange({
                schedule: e.target.checked ? "0 0 2 * * *" : "",
                timezone: timezone || "UTC",
              })
            }
            className="mt-0.5 h-4 w-4 rounded accent-blue-600"
          />
          <span>
            <span className="text-sm font-semibold text-slate-900">
              Run on a schedule
            </span>
            <span className="mt-1 block text-xs leading-relaxed text-slate-500">
              Off means the job runs only when someone starts it, or when a webhook
              or an agent triggers it.
            </span>
          </span>
        </label>
      </Card>

      {enabled && (
        <>
          <Card className="p-6">
            <h3 className="mb-4 text-sm font-semibold text-slate-900">How often</h3>
            <div className="mb-5 flex flex-wrap gap-2">
              {PRESETS.map((p) => (
                <button
                  key={p.cron}
                  onClick={() => onChange({ schedule: p.cron, timezone })}
                  className={`rounded-lg border px-3 py-1.5 text-xs font-medium transition ${
                    schedule === p.cron
                      ? "border-blue-600 bg-blue-600 text-white"
                      : "border-slate-200 bg-slate-50 text-slate-700 hover:border-blue-500"
                  }`}
                >
                  {p.label}
                </button>
              ))}
            </div>

            <div className="grid gap-5 md:grid-cols-2">
              <div>
                <label className={label}>Cron expression</label>
                <input
                  value={schedule}
                  onChange={(e) =>
                    onChange({ schedule: e.target.value, timezone })
                  }
                  placeholder="0 0 2 * * *"
                  className={`${inputCls} font-mono`}
                />
                <p className="mt-1 text-[11px] leading-relaxed text-slate-500">
                  Six fields:{" "}
                  <code className="font-mono">
                    second minute hour day month weekday
                  </code>
                </p>
              </div>
              <div>
                <label className={label}>Timezone</label>
                <select
                  value={timezone || "UTC"}
                  onChange={(e) =>
                    onChange({ schedule, timezone: e.target.value })
                  }
                  className={inputCls}
                >
                  {timezoneOptions().map((tz) => (
                    <option key={tz.value} value={tz.value}>
                      {tz.label}
                    </option>
                  ))}
                </select>
                <p className="mt-1 text-[11px] leading-relaxed text-slate-500">
                  Stored with the schedule, so daylight saving does not silently
                  move the run.
                </p>
              </div>
            </div>
          </Card>

          <Card className="border-slate-200 bg-slate-50/60 p-4">
            <div className="flex items-start gap-3 text-xs leading-relaxed text-slate-600">
              <span className="mt-0.5 text-slate-400">
                <Icon name="clock" size={15} />
              </span>
              <p>
                A scheduled run carries no operator, so it skips the plan
                entitlement check and uses each option's default value. If an
                option is required and has no default, schedule the job only after
                giving it one.
              </p>
            </div>
          </Card>
        </>
      )}
    </div>
  );
}
