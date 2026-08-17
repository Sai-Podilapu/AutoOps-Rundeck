# workflow-service

Automation workflow **definitions** (port **8086**, MySQL `autoops_workflow`). Boot 3.4.2 / Java 21. Every row is tenant-scoped by the JWT `tenantId` claim — never a header.

Split out of core-service. The console's paths, payloads and error codes are unchanged (`workflow_not_found`, `workflow_exists`, `invalid_definition`, `quota_exceeded`, …) — the gateway simply points `/api/workflows/**` and `/api/projects/{id}/workflows` here instead.

## What this service owns, and what it does not

| | Owner |
|---|---|
| Workflow rows, canvas JSON, node count, enabled flag | **workflow-service** |
| MAX_AUTOMATIONS / MAX_NODES enforcement on workflows | **workflow-service** |
| Running a workflow, run history, cancellation | core-service |
| Approval interception + the tenant's complexity rules | core-service |
| Projects, jobs, audit trail | core-service |

`POST /api/workflows/{id}/run` is therefore **not** here: triggering is execution, and the run engine, approval gate and run history all stayed in core-service. The gateway routes that one path to :8083, ahead of the `/api/workflows/**` route (first predicate wins).

## Endpoints

- `GET/POST /api/projects/{projectId}/workflows`
- `GET/PUT/DELETE /api/workflows/{id}`, `POST /api/workflows/{id}/enable|disable`

Internal (shared-secret `X-Internal-Token`, never routed by the gateway):

- `GET /internal/workflows/{id}?tenantId=` → the projection core-service works with
- `GET /internal/projects/{projectId}/workflows?tenantId=` → SCM export, compliance evidence
- `POST /internal/projects/{projectId}/workflows`, `PUT /internal/workflows/{id}` → SCM import (the user's token rides along in `X-Access-Token` so the plan gate still applies)
- `GET /internal/workflows/count?tenantId=` → the workflow half of the shared automation budget
- `GET /internal/workflows/counts` → per-tenant counts for the provider usage table

## What the split cost, and how each cost is handled

- **No foreign key to `projects`.** The owning project is confirmed over core-service's `/internal/projects/{id}` on every write, and that check **fails closed**: an unreachable core-service returns 503, never a workflow attached to an unverified project.
- **Run stats and `requiresApproval` come from core-service** on every list/get, so a workflow response still carries `runsTotal`, `successRate`, `lastRunAt` and the approval flag. These calls **degrade** rather than fail — stats fall back to empty and the complexity rules to the platform defaults, because a workflow list must still render when core-service is down. Note the direction of the fallback: defaults keep complex workflows gated.
- **The automation budget is shared with agents**, which live in agent-service. Creating a workflow asks `/internal/agents/count`. An unreachable agent-service counts 0 rather than blocking creation — a rare over-count that self-corrects beats an outage in the primary feature.
- **`WorkflowComplexity` is duplicated** here and in core-service. It takes `(definition, nodeCount, rules)` — data only — so the two copies cannot drift on anything but the arithmetic, and the rules themselves still live in exactly one place (core-service's `approval_settings`).

## Configuration

`SERVER_PORT`, `DB_*`, `AUTH_JWKS_URI`, `JWT_ISSUER`, `SUBSCRIPTION_SERVICE_URL`, `ENTITLEMENT_FAIL_OPEN`, `CORE_SERVICE_URL`, `AGENT_SERVICE_URL`, and the three shared secrets `CORE_INTERNAL_TOKEN` / `AGENT_INTERNAL_TOKEN` (presented to peers) and `WORKFLOW_INTERNAL_TOKEN` (required on this service's own `/internal/**`).

## Migrating an existing deployment

The table moved whole, columns unchanged, so the rows are a straight copy — do it **before** core-service's `V23` renames the old table away:

```sql
INSERT INTO autoops_workflow.workflows SELECT * FROM autoops_core.workflows;
```

## Tests

`mvn test` — 16 tests against H2 with the peers mocked: node counting and MAX_NODES, the shared automation budget, tenant isolation, duplicate names, and the two cases the split introduced (an unknown project stops the create; an unreachable core-service fails closed).
