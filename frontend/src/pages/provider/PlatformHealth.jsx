import React, { useCallback, useEffect, useRef, useState } from "react";
import {
  PageHeader,
  Card,
  StatCard,
  StatusBadge,
  SmallButton,
  Chip,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";

// Poll cadence. Each poll fans out to every service, so this is also how often
// the platform gets probed — fast enough to catch an outage during a demo,
// slow enough not to be a load source of its own.
const REFRESH_MS = 15000;

const ICONS = {
  coreDatabase: "server",
  apiGateway: "cloud",
  authService: "lock",
  subscriptionService: "scale",
  jobService: "play",
  workflowService: "blocks",
  agentService: "robot",
  voiceAgent: "sparkles",
};

// Only used when the backend predates the richer `services` payload.
const LEGACY = [
  ["coreDatabase", "Core database"],
  ["jobService", "Job service"],
  ["subscriptionService", "Subscription service"],
];

const servicesOf = (health) => {
  if (!health) return [];
  if (Array.isArray(health.services) && health.services.length) {
    return health.services;
  }
  return LEGACY.filter(([key]) => health[key]).map(([key, label]) => ({
    key,
    label,
    status: String(health[key]),
    latencyMs: null,
  }));
};

const ago = (iso, now) => {
  if (!iso) return "—";
  const secs = Math.max(0, Math.round((now - new Date(iso).getTime()) / 1000));
  if (secs < 60) return `${secs}s ago`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`;
  return `${Math.floor(secs / 3600)}h ago`;
};

const latency = (ms) => (ms === null || ms === undefined ? "—" : `${ms} ms`);

export default function PlatformHealth() {
  const { pushToast } = useStore();
  const [health, setHealth] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [now, setNow] = useState(() => Date.now());
  // Toast only on the first failure of a streak — a service that stays down
  // must not produce a toast every 15 seconds.
  const wasFailing = useRef(false);

  const load = useCallback(
    async (silent) => {
      if (!silent) setLoading(true);
      try {
        const h = await api.providerHealth();
        setHealth(h || null);
        setError(null);
        wasFailing.current = false;
      } catch (err) {
        const message = err.message || "Could not load platform health";
        setError(message);
        if (!wasFailing.current) {
          pushToast(message, "red");
          wasFailing.current = true;
        }
      } finally {
        if (!silent) setLoading(false);
      }
    },
    [pushToast],
  );

  useEffect(() => {
    load(false);
    const poll = setInterval(() => {
      // A backgrounded tab does not need to probe eight services.
      if (document.visibilityState === "visible") load(true);
    }, REFRESH_MS);
    const tick = setInterval(() => setNow(Date.now()), 1000);
    return () => {
      clearInterval(poll);
      clearInterval(tick);
    };
  }, [load]);

  const services = servicesOf(health);
  const down = services.filter((s) => s.status !== "UP");
  const allUp = services.length > 0 && down.length === 0;
  const metrics = health?.metrics || {};
  const scheduler = health?.scheduler || {};

  // Headline is the real registry count from auth-service; the subset that
  // actually owns a project rides underneath, because the gap between them is
  // the interesting part — tenants who signed up and never started.
  const tiles = [
    [
      "Tenants",
      metrics.tenantsTotal === null || metrics.tenantsTotal === undefined
        ? metrics.tenants
        : metrics.tenantsTotal,
      "users",
      "violet",
      metrics.tenants === undefined ? null : `${metrics.tenants} with projects`,
    ],
    ["Projects", metrics.projects, "folder", "cyan"],
    [
      "Jobs",
      metrics.jobs,
      "list",
      "cyan",
      metrics.jobsEnabled === undefined
        ? null
        : `${metrics.jobsEnabled} enabled`,
    ],
    ["Runs · 24h", metrics.runs24h, "play", "emerald"],
    ["Failed · 24h", metrics.failed24h, "warning", "red"],
    ["Running now", metrics.running, "pulse", "amber"],
  ];

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Platform Health"
        subtitle="Live status of every service behind AutoOps"
        actions={
          <div className="flex items-center gap-3">
            <span className="flex items-center gap-1.5 text-xs text-slate-500">
              <span
                className={`h-1.5 w-1.5 rounded-full ${error ? "bg-red-400" : "animate-pulse-dot bg-emerald-400"}`}
              />
              {error ? "Reconnecting" : `Live · ${ago(health?.checkedAt, now)}`}
            </span>
            <SmallButton icon="pulse" onClick={() => load(true)}>
              Refresh
            </SmallButton>
          </div>
        }
      />

      {loading ? (
        <Card className="p-10 text-center text-sm text-slate-500">
          Checking services…
        </Card>
      ) : !health ? (
        <Card className="p-10 text-center text-sm text-red-600">
          {error || "No health data yet."}{" "}
          <button
            onClick={() => load(false)}
            className="ml-2 text-slate-900 underline"
          >
            Try again
          </button>
        </Card>
      ) : (
        <>
          <Card
            className={`mb-6 flex flex-wrap items-center justify-between gap-3 p-4 ${
              allUp
                ? "border-emerald-400/20 bg-emerald-400/[0.04]"
                : "border-red-400/20 bg-red-400/[0.04]"
            }`}
          >
            <p
              className={`flex items-center gap-2 text-sm font-medium ${allUp ? "text-emerald-700" : "text-red-700"}`}
            >
              <Icon name={allUp ? "check" : "warning"} size={16} />
              {allUp
                ? `All ${services.length} services operational.`
                : `${down.length} of ${services.length} services down — ${down
                    .map((s) => s.label)
                    .join(", ")}.`}
            </p>
            <div className="flex flex-wrap items-center gap-3 text-xs text-slate-500">
              {health.executionMode && (
                <span className="flex items-center gap-1.5">
                  Execution mode <Chip>{health.executionMode}</Chip>
                </span>
              )}
              {metrics.dbLatencyMs !== undefined && (
                <span className="flex items-center gap-1.5">
                  Database <Chip>{latency(metrics.dbLatencyMs)}</Chip>
                </span>
              )}
            </div>
          </Card>

          {/* Real counters, straight off the platform's own tables. */}
          <div className="mb-6 grid gap-4 sm:grid-cols-3 lg:grid-cols-6">
            {tiles.map(([label, value, icon, tone, hint]) => (
              <StatCard
                key={label}
                label={label}
                value={value === undefined ? "—" : String(value)}
                icon={icon}
                tone={tone}
                hint={hint}
              />
            ))}
          </div>

          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            {services.map((s) => {
              const up = s.status === "UP";
              return (
                <Card key={s.key} className="p-5">
                  <div className="flex items-start justify-between">
                    <span
                      className={`flex h-10 w-10 items-center justify-center rounded-xl ${
                        up
                          ? "bg-emerald-400/10 text-emerald-600"
                          : "bg-red-400/10 text-red-600"
                      }`}
                    >
                      <Icon name={ICONS[s.key] || "server"} size={20} />
                    </span>
                    <StatusBadge status={up ? "healthy" : "offline"} />
                  </div>
                  <p className="mt-4 text-sm font-semibold text-slate-900">
                    {s.label}
                  </p>
                  <div className="mt-1 flex items-baseline justify-between">
                    <span
                      className={`text-xl font-bold ${up ? "text-emerald-600" : "text-red-600"}`}
                    >
                      {s.status}
                    </span>
                    <span className="font-mono text-xs text-slate-500">
                      {latency(s.latencyMs)}
                    </span>
                  </div>
                </Card>
              );
            })}
          </div>

          {/* Nothing fires scheduled jobs without this lease, and its absence
              is otherwise completely invisible. */}
          {scheduler.status && (
            <Card className="mt-6 flex flex-wrap items-center justify-between gap-3 p-5">
              <div className="flex items-center gap-3">
                <span
                  className={`flex h-10 w-10 items-center justify-center rounded-xl ${
                    scheduler.status === "UP"
                      ? "bg-emerald-400/10 text-emerald-600"
                      : "bg-amber-400/10 text-amber-600"
                  }`}
                >
                  <Icon name="clock" size={20} />
                </span>
                <div>
                  <p className="text-sm font-semibold text-slate-900">
                    Cron scheduler lease
                  </p>
                  <p className="text-xs text-slate-500">
                    {scheduler.status === "UP"
                      ? "A node holds the lease and is firing due jobs."
                      : scheduler.status === "STALE"
                        ? "Lease expired — no node is firing scheduled jobs."
                        : "No node has claimed the lease yet."}
                  </p>
                </div>
              </div>
              <div className="flex flex-wrap items-center gap-3 text-xs text-slate-500">
                {scheduler.holder && (
                  <span className="font-mono">{scheduler.holder}</span>
                )}
                <StatusBadge
                  status={scheduler.status === "UP" ? "healthy" : "offline"}
                />
              </div>
            </Card>
          )}
        </>
      )}
    </div>
  );
}
