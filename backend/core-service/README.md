# AutoOps Core Service

Projects, jobs, and the execution engine (port **8083**). Boot 3.4.2 / Java 21, MySQL (`autoops_core`). Every business row is tenant-scoped by the JWT `tenantId` claim — never a header.

## The subscription gate

Auth-service authenticates the user; **this service performs an operation only if the tenant's subscription allows it**, decided live by subscription-service (`POST /api/entitlements/check` with the end user's own bearer token):

| Business status | Platform status | Mutations (create/update/archive/…) | Reads |
|---|---|---|---|
| PAID | `ACTIVE` / `TRIALING` | ✅ allowed (quota permitting) | ✅ |
| PENDING | `PAST_DUE` | ❌ `subscription_past_due` | ✅ |
| CANCELLED | `CANCELED` | ✅ until period end, then ❌ `subscription_canceled` | ✅ |
| REVOKED | `EXPIRED` / expired trial | ❌ `subscription_expired` / `trial_expired` | ✅ |
| — | none | ❌ `no_subscription` | ✅ |

- **Reads are never gated** — a tenant can always see and export its own data; only *doing new things* requires a live subscription.
- Denials are HTTP 403 with the reason as the `error` code so the frontend can show the right renew/upgrade prompt.
- **Fail-closed**: if subscription-service is unreachable, mutations get 503 `entitlement_unavailable` (set `ENTITLEMENT_FAIL_OPEN=true` to invert during outages). `core_gate_checks_total` counts every gate decision.

## Quota enforcement (count locally, ask centrally)

| Resource | Limit | Count basis | Freed by |
|---|---|---|---|
| Projects | `MAX_PROJECTS` | ACTIVE projects in tenant | archiving (restore re-checks) |
| Workflows + agents | `MAX_AUTOMATIONS` | enforced by **workflow-service** and **agent-service**, which count each other over `/internal` (one shared budget — both are automations) | deleting either |
| Nodes per workflow | `MAX_NODES` | `nodes` array size, parsed **server-side** from the canvas JSON | shrinking the definition |
| Jobs | `MAX_JOBS` | all jobs in tenant | deleting |
| Cloud integrations | `MAX_CLOUD_INTEGRATIONS` | CONNECTED connections in tenant | disconnecting (record survives) |

Over-limit tenants after a downgrade are grandfathered: existing resources survive, new creations are blocked (`quota_exceeded`, message carries the plan max).

## Execution engine (runs)

One `runs` row per execution of a job (its `steps[]`) or workflow (its `nodes[]`). The target's **name and definition are snapshotted onto the run** — history stays truthful after edits/deletes (no FK to the target).

- **Lifecycle**: `QUEUED → RUNNING → SUCCEEDED | FAILED | CANCELED`. Execution is async on a bounded pool (`EXECUTION_POOL_SIZE`, default 4); triggers return `202` immediately, poll `GET /api/runs/{id}` for live progress (`stepCompleted/stepTotal` + log stream).
- **Step execution seam**: `StepExecutor` is the interface with two implementations selected by `EXECUTION_MODE`: `remote` (compose default) sends every step to **job-service**, which REALLY executes it (shell command, script, python, ssh, REST — see job-service/README.md) and returns the captured output into the run log; `simulated` (bare-metal dev default) sleeps 300–1500ms per step and succeeds (`"simulate":"fail"` fails deterministically — demo/test hook). Cloud-platform steps (terraform, kubernetes, awslambda, azurefn) are live in job-service: `JobServiceStepExecutor` resolves the step's cloud integration, decrypts it, and ships the bundle with the execute call — missing or ambiguous integrations fail the step with a clear message instead of running blind.
- **Triggers**: `POST /api/jobs/{id}/run` and `POST /api/workflows/{id}/run` are gated mutations. **Cancel**: `POST /api/runs/{id}/cancel` sets a flag the engine honors between steps (409 `run_finished` if already terminal).
- **Per-step reliability policy** (from the step's own JSON, Rundeck-style): `retries` (0–5; a failed attempt waits `EXECUTION_RETRY_DELAY`, default 2s, then re-runs — cancel wins over a pending retry) and `continueOnError` (a non-critical step's failure is logged and the pipeline proceeds; the run still ends SUCCEEDED, noting the ignored failure count). Every attempt is stamped in the log (`[attempt 2/3]`).
- **Scheduler**: jobs may carry a cron `schedule` (5-field unix or 6-field Spring, validated on save → 400 `invalid_schedule`; evaluated in UTC). A DB poller (`SCHEDULER_POLL_INTERVAL`, default 30s) fires due jobs and advances `next_run_at`. Multiple replicas are safe: `SchedulerLeaseService` holds a DB lease (90s TTL, renewed each poll, stealable only after expiry) so exactly one instance polls, and a crashed leader is replaced within the TTL. *Accepted trade-off*: scheduled runs carry no user token, so they skip the entitlement gate.
- **Retention (read-time bound, not a quota)**: run history reads are bounded by the plan's `history_days` (from `GET /api/subscriptions/current`, cached 60s). Older runs vanish from lists and 404 by id. Never fail-closed — if subscription-service is down, history is unbounded until it recovers.
- **Stats**: workflow/job responses carry `runsTotal`, `successRate`, `lastRunAt`, `avgDurationMs` aggregated from finished runs (one batch query per list). `core_runs_total{status,trigger}` counts terminal runs.

## Endpoints

- `GET/POST /api/projects`, `GET/PUT /api/projects/{id}`, `POST /api/projects/{id}/archive|restore`
- `GET/POST /api/projects/{projectId}/jobs`
- `GET/PUT/DELETE /api/jobs/{id}`, `POST /api/jobs/{id}/enable|disable`
- `GET/POST /api/cloud/connections`, `DELETE /api/cloud/connections/{id}` (= disconnect)
- `POST /api/jobs/{id}/run`, `POST /api/workflows/{id}/run` (202: queued)
- `GET /api/projects/{projectId}/runs` (newest 200, retention-bounded), `GET /api/runs/{id}` (with log), `POST /api/runs/{id}/cancel`
- `GET/POST /api/projects/{projectId}/compliance/reports`, `GET /api/compliance/reports/{id}`, `GET /api/compliance/reports/{id}/download` (PDF, rendered with openhtmltopdf)
- `GET /api/governance/summary`, `PUT /api/governance/policies/{policy}` (admin, `{mode}`)

All routed through the gateway (`/api/projects/**`, `/api/jobs/**`, `/api/cloud/**`, `/api/runs/**`, `/api/approvals/**`, `/api/compliance/**`, `/api/governance/**` → 8083). Workflow CRUD went to **workflow-service** and agents to **agent-service**; `POST /api/workflows/{id}/run` stayed here and the gateway routes that one path back to 8083.

Internal (shared-secret `X-Internal-Token`, never routed by the gateway) — what the split-out services still need from here:

- `GET /internal/projects/{id}?tenantId=` (existence + tenancy), `GET /internal/jobs/{id}`, `GET /internal/projects/{projectId}/jobs`
- `GET /internal/runs/stats?tenantId=&targetType=&projectId=` — the stats workflow responses carry
- `GET /internal/approval-settings?tenantId=` — the tenant's complexity rules
- `POST /internal/audit` — one event into the single audit trail

## Workflows and agents live in their own services

Workflow definitions moved to **workflow-service** (:8086, `autoops_workflow`) and AI agents to **agent-service** (:8087, `autoops_agent`). See their READMEs.

What stayed here is everything workflows are entangled with — and it is a lot, which is why the seam matters:

| Consumer | What it needs | How it gets it now |
|---|---|---|
| `RunService` | name + definition to snapshot onto a run | `WorkflowClient.require` |
| `ApprovalService` | definition + node count to judge complexity | `WorkflowClient.require` |
| `GovernanceService` | owning project; tenant workflow count | `WorkflowClient.find` / `countForTenant` |
| `WebhookService` | WORKFLOW-targeted hooks | `WorkflowClient.find` / `require` |
| `ScmService` | list for export, create/update for import | `WorkflowClient.listByProject` / `create` / `update` |
| `ComplianceService` | list + complexity for evidence | `WorkflowClient.listByProject` |
| `ProviderController` | per-tenant counts for the usage table | `WorkflowClient.countsByTenant` |

`WorkflowClient` **never treats an unreachable workflow-service as "no such workflow"**: `find` returns empty only on a real 404, and anything else throws 503 `workflow_unavailable`. Collapsing the two would let an outage look like a deletion — which in the governance and compliance paths would silently report a project as having no workflows to gate. The two dashboard reads (`countForTenant`, `countsByTenant`) are the deliberate exceptions and degrade to 0.

`WorkflowComplexity` is duplicated in workflow-service so it can compute `requiresApproval` for its own responses. It takes `(definition, nodeCount, rules)` — data only — and the rules stay here in `approval_settings`, so there is one source of truth for the policy and two copies of the arithmetic.

## Governance

A live policy engine over real workspace data — violations are computed on read, never stored, so fixing the cause clears them. The catalog: **RISKY_APPROVAL** (derived from approval settings: enforced iff risky-type gating is on), **CREDENTIAL_HYGIENE** (enforced by design: disconnect purges credentials; a disconnected row that still holds them is a violation), and three configurable policies stored per tenant (`governance_policies`, no row = default): **SCM_REQUIRED** (active projects must have git sync; default Monitor), **FAILURE_BUDGET** (≤25% failure rate over 30 days, min 4 finished runs; default Monitor) and **APPROVAL_SLA** (pending approvals decided within 7 days; Monitor/Disabled only).

ENFORCED has teeth: SCM_REQUIRED and FAILURE_BUDGET in Enforced mode block MANUAL runs in violating projects with 403 `policy_scm_required` / `policy_failure_budget` (the cron scheduler is not blocked — same trade-off as the approval gate). Mode changes are ADMIN-only and gated on the `GOVERNANCE` plan feature (Business+); the summary endpoint also returns the compliance score (average of each active project's latest report), quota usage (worst utilization across plan limits) and the real state of the platform's automations.

## Compliance reports

`POST /api/projects/{pid}/compliance/reports {framework: SOC2|ISO_27001|HIPAA|PCI_DSS|GDPR}` (lenient parse — "SOC 2", "pci-dss" work) evaluates the framework's control set against the project's **real** posture and stores a point-in-time findings snapshot (JSON on the row), so a report stays stable evidence as the project changes. Generation requires the `COMPLIANCE_REPORTS` plan feature (Business+); reads and downloads are never gated.

Controls are backed by live data, not theater: approval gating on jobs/risky workflows (change authorization), requester ≠ approver on recorded decisions (segregation of duties), stale pending approvals (timely review), AES-256-GCM credential storage and credential purge on disconnect, SCM sync configured (version control), plan `history_days` vs. the framework's retention guideline, and the last 30 days of run outcomes (failure rate >25% fails, >10% warns). Score = passed + half-credit for warnings over applicable controls; any failing control makes the report `NON_COMPLIANT`.

## Run

```
mvn spring-boot:run -Dspring-boot.run.profiles=dev   # dev: MySQL on host port 3307
mvn test                                             # hermetic H2 suite, gate mocked
```

First-time DB (existing MySQL container predates `autoops_core` in mysql-init):

```
docker exec -i <mysql-container> mysql -uroot -p<rootpw> -e "CREATE DATABASE IF NOT EXISTS autoops_core CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci; GRANT ALL PRIVILEGES ON autoops_core.* TO 'autoops'@'%'; FLUSH PRIVILEGES;"
```

With the `prod` profile, `ProdSafetyGuard` refuses startup on dev defaults (DB password, localhost JWKS/subscription URL, fail-open gating); Swagger off, TLS to MySQL required.
