// All 10 feature pages are data-driven through this file and rendered by
// src/pages/FeaturePage.jsx at /features/:slug

export const FEATURES = [
  {
    slug: "real-time-ingestion",
    icon: "bolt",
    title: "Real-time ingestion",
    tagline: "Stream every event the moment it happens",
    description:
      "Pipe events, metrics, and execution output into AutoOps with millisecond latency. Built on a Kafka-backed event bus, ingestion scales horizontally so no signal is ever dropped.",
    bullets: [
      "Kafka-backed event bus with at-least-once delivery",
      "Live SSE & WebSocket streams to the UI",
      "Back-pressure aware, horizontally scalable consumers",
      "Structured, queryable event envelopes",
    ],
    stat: { value: "<50ms", label: "ingest latency" },
  },
  {
    slug: "sandbox-isolation",
    icon: "shield",
    title: "Sandbox isolation",
    tagline: "Run untrusted steps without fear",
    description:
      "Every job step executes in an isolated, ephemeral sandbox with scoped credentials and no shared state. Blast radius stays exactly where it should — contained.",
    bullets: [
      "Ephemeral, per-execution executors",
      "Scoped, short-lived credentials",
      "No shared filesystem or network by default",
      "Automatic teardown after every run",
    ],
    stat: { value: "100%", label: "isolated runs" },
  },
  {
    slug: "secure-apis",
    icon: "api",
    title: "Secure APIs",
    tagline: "A versioned API you can trust",
    description:
      "Everything in the UI is available through a documented, versioned REST API secured with scoped tokens and signed claims — perfect for CI/CD and integrations.",
    bullets: [
      "OpenAPI 3 spec for every endpoint",
      "Scoped, revocable API tokens",
      "Server-side authorization on every route",
      "First-class CI/CD integration",
    ],
    stat: { value: "OpenAPI 3", label: "fully documented" },
  },
  {
    slug: "zero-latency",
    icon: "pulse",
    title: "Zero-latency control",
    tagline: "Push commands, skip the polling",
    description:
      "AutoOps maintains persistent control channels to every node, so commands dispatch instantly without wasteful polling loops or cron drift.",
    bullets: [
      "Persistent agent control channels",
      "Instant command dispatch",
      "No polling overhead or cron drift",
      "Real-time node health signals",
    ],
    stat: { value: "0", label: "polling loops" },
  },
  {
    slug: "intelligent-audit",
    icon: "search",
    title: "Intelligent audit",
    tagline: "Answers, not just log lines",
    description:
      "Every action is captured as a searchable, attributed audit event. Filter by user, project, or resource and reconstruct exactly what happened, when, and why.",
    bullets: [
      "Attributed, searchable audit events",
      "Filter by actor, project, or resource",
      "Streamed to Kafka for downstream SIEM",
      "Tamper-evident event chain",
    ],
    stat: { value: "Every", label: "action captured" },
  },
  {
    slug: "composable-workflows",
    icon: "blocks",
    title: "Composable workflows",
    tagline: "Build once, reuse everywhere",
    description:
      "Turn jobs, scripts, and runbooks into reusable building blocks. Compose them into larger DAGs with inputs, outputs, and approval gates — no copy-paste required.",
    bullets: [
      "Reusable jobs, templates & runbooks",
      "Typed inputs and outputs between steps",
      "Branching, fan-out / fan-in, approvals",
      "Version-controlled workflow definitions",
    ],
    stat: { value: "∞", label: "reusable blocks" },
  },
  {
    slug: "automated-runbooks",
    icon: "book",
    title: "Automated runbooks",
    tagline: "Turn tribal knowledge into one click",
    description:
      "Capture operational procedures as executable runbooks. What used to be a wiki page and a prayer becomes a safe, repeatable, audited one-click operation.",
    bullets: [
      "Procedures as executable runbooks",
      "Parameterized, guarded execution",
      "One-click incident response",
      "Full audit trail on every run",
    ],
    stat: { value: "1-click", label: "operations" },
  },
  {
    slug: "access-control",
    icon: "lock",
    title: "Access control",
    tagline: "Default-deny, enforced server-side",
    description:
      "Fine-grained RBAC backed by Keycloak. Roles come from signed claims, never the client, and every controller enforces a default-deny policy.",
    bullets: [
      "Keycloak-backed identity & SSO",
      "Signed-claim roles — never client-trusted",
      "Default-deny on every controller",
      "Per-project and per-resource policies",
    ],
    stat: { value: "Deny", label: "by default" },
  },
  {
    slug: "execution-audit-trails",
    icon: "trail",
    title: "Execution audit trails",
    tagline: "A tamper-evident record of every run",
    description:
      "Each execution writes an immutable, time-ordered trail — inputs, steps, outputs, and approvals — streamed to Kafka for compliance and forensics.",
    bullets: [
      "Immutable, time-ordered run history",
      "Inputs, outputs & approvals captured",
      "Compliance-ready exports",
      "Streamed to Kafka for retention",
    ],
    stat: { value: "Immutable", label: "run history" },
  },
  {
    slug: "environment-discovery",
    icon: "radar",
    title: "Environment discovery",
    tagline: "Always know what you're running on",
    description:
      "AutoOps automatically discovers nodes, clusters, and cloud assets across AWS, Azure, GCP, OCI, and Kubernetes — keeping your inventory live and accurate.",
    bullets: [
      "Auto-discovery across clouds & clusters",
      "Live, always-accurate inventory",
      "Tag-based node selection",
      "Drift and health detection",
    ],
    stat: { value: "Live", label: "inventory" },
  },
];

export const getFeature = (slug) => FEATURES.find((f) => f.slug === slug);