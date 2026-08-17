// Execution-throughput buckets built from real run timestamps.
//
// The Dashboard and Project Overview pages used to declare `const throughput =
// []`, so the chart rendered zero bars no matter how many runs existed. This
// is the shared, honest version: it buckets the rows returned by
// api.list("executions") — whose statuses are already lowercased by mapRun
// ("success" / "failed" / "running" / "queued" / "cancelled").

export const THROUGHPUT_RANGES = [
  { key: "15m", label: "Last 15 min", buckets: 15, stepMs: 60_000 },
  { key: "1h", label: "Last 1 hour", buckets: 12, stepMs: 5 * 60_000 },
  { key: "24h", label: "Last 24 hours", buckets: 24, stepMs: 60 * 60_000 },
  { key: "7d", label: "Last 7 days", buckets: 7, stepMs: 24 * 60 * 60_000 },
  { key: "30d", label: "Last 30 days", buckets: 30, stepMs: 24 * 60 * 60_000 },
];

// Default to a week: a run from yesterday should still be visible when the
// page is opened, which a 12-hour window silently hid.
export const DEFAULT_RANGE = "7d";

const DAY_MS = 24 * 60 * 60_000;
const pad = (n) => String(n).padStart(2, "0");

const bucketLabel = (date, stepMs) =>
  stepMs >= DAY_MS
    ? `${date.getMonth() + 1}/${date.getDate()}`
    : `${pad(date.getHours())}:${pad(date.getMinutes())}`;

// Runs carry createdAt; startedAt is the fallback for rows written by an
// older engine version. Anything unparseable is dropped rather than bucketed
// at the epoch.
function runTime(execution) {
  const raw = execution?.createdAt || execution?.startedAt;
  const t = raw ? new Date(raw).getTime() : NaN;
  return Number.isNaN(t) ? null : t;
}

export function rangeFor(rangeKey) {
  return (
    THROUGHPUT_RANGES.find((r) => r.key === rangeKey) ||
    THROUGHPUT_RANGES.find((r) => r.key === DEFAULT_RANGE)
  );
}

/**
 * @returns {{label: string, success: number, failed: number, running: number,
 *            total: number}[]} one entry per bucket, oldest first.
 */
export function buildThroughput(
  executions,
  rangeKey = DEFAULT_RANGE,
  now = Date.now(),
) {
  const { buckets: count, stepMs } = rangeFor(rangeKey);
  const windowStart = now - count * stepMs;

  const out = Array.from({ length: count }, (_, i) => ({
    label: bucketLabel(new Date(windowStart + i * stepMs), stepMs),
    success: 0,
    failed: 0,
    running: 0,
    total: 0,
  }));

  for (const execution of executions || []) {
    const t = runTime(execution);
    if (t === null || t < windowStart || t > now) continue;
    // Clamp: a run landing exactly on `now` would otherwise index past the end.
    const i = Math.min(count - 1, Math.floor((t - windowStart) / stepMs));
    const bucket = out[i];
    const status = String(execution.status || "").toLowerCase();
    if (status === "success") bucket.success += 1;
    else if (status === "failed") bucket.failed += 1;
    else bucket.running += 1; // queued / running / cancelled
    bucket.total += 1;
  }

  return out;
}