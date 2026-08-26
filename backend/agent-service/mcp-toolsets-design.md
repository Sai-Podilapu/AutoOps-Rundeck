# MCP and toolsets — design

Status: **proposed**, not built. Written 2026-08-25.

## Why

The reasoning half of the agent platform is finished and good. `agent-runtime`
runs phased graphs, narrows the toolbox per phase, and refuses to report a claim
it cannot cite. None of that is the constraint.

The constraint is that an agent's entire universe of tools is *the jobs and Dify
workflows a customer already built by hand*. `AgentToolbox.build` (line 111)
walks an allow-list of exactly two ref types, JOB and WORKFLOW, and resolves each
one by id. There is no third kind of tool and no way to acquire one except a
human authoring an automation.

So agents reason well about almost nothing. MCP is the fix: point at a server,
get its tools, and the agent's reach grows without anyone authoring an
automation. "Toolsets" is the same change seen from the catalog side — the unit
a provider seals and ships, and the unit an agent references.

This document is about how MCP lands **without** giving up the properties that
make the current design defensible: one enforcement point, approvals in one
inbox, an audit row per step, and an evidence id per observation.

## What a tool is today, exactly

```
agent.tools (JSON)  [{"type":"JOB","id":14,"mutating":false}, ...]
        │
        ▼  AgentToolbox.build  — re-validates every id against its owning
        │                        service, fails closed, records a `skipped`
        │                        reason for anything it cannot offer
        ▼
Tool(name="job_14", type="JOB", targetId=14L, targetName=…, mutating=…)
ToolSpec(name, description, jsonSchema)
        │
        ▼  Toolbox.offered()  →  OfferedTool(spec, mutating)  →  the wire
        ▼
agent-runtime: ToolSpecWire{name, description, input_schema, mutating}
        │
        ▼  toolbox.py PHASE_ACCESS — GATHER binds only non-mutating entries
        ▼
model emits a call  →  Java  →  AgentToolbox.resolve(name)  →  Tool or null
```

Three properties fall out of this and all three are load-bearing:

1. **`resolve` answers only from this agent's own allow-list.** A hallucinated
   name is an error the model is told about, never a lookup that finds
   something.
2. **`mutating` is decided by Java and travels with the tool.** It is the only
   input to phase narrowing. A misclassification hands an evidence-gathering
   phase something destructive.
3. **Every tool result is an `agent_run_steps` row, and that row's id is the
   citation.** `recordStep` (line 1130) returns it. The evidence ledger is an
   index over rows the audit trail was writing anyway.

MCP must preserve all three. It does not threaten any of them.

## The assumption MCP actually breaks

`AgentRunService.invoke` (line 790) does this, and only this:

```java
dispatch = automations.dispatch(tenantId, actor, tool.type(), tool.targetId(), args);
if (dispatch.needsApproval()) return Outcome.park(dispatch.approvalId());
return Outcome.of(watch(run, tool, call.id(), dispatch.runId(), began));
```

Every tool call is *dispatched to core-service, which returns either an approval
id or a run id, and then polled to completion*. That single path is where
approvals, the Runs view, the actor attribution and the tool audit rows all come
from.

An MCP `tools/call` has none of that shape. It is synchronous, returns in
milliseconds to seconds, produces no run row, and core-service knows nothing
about it. **There is no approval id to park on.**

That is the whole design problem. Everything else is plumbing.

## The decision: read-only first, and it is not a compromise

Split MCP into two deliveries, divided by mutability.

**Phase 1a — read-only MCP tools only.** A read-only tool needs no approval, so
the missing approval path costs nothing. `invoke` gets a second branch that
calls the server directly, records a `TOOL_RESULT` step, and returns an
`Observed` with its evidence id. No core-service change. No approvals change.

**Phase 1b — mutating MCP tools, routed through core-service** as a new
automation target type, so they acquire a run row, the approvals inbox and the
Runs view exactly as jobs and workflows do.

Two reasons this ordering is right rather than merely convenient:

- **The value is in 1a.** Agents today cannot *see* anything. `GATHER` is the
  starved phase. A read-only MCP server — a monitoring API, a cloud inventory, a
  ticketing system — is precisely the evidence supply that is missing.
- **It fails safe by construction.** `AgentToolbox.mutating` (line 286) already
  defaults an unmarked entry to *mutating*, and the comment there explains why:
  guessing read-only is the failure the narrowing exists to prevent. Under 1a,
  "mutating" additionally means "not offered at all". An unclassified MCP tool is
  therefore invisible until a human classifies it. That is the correct direction
  for the door to swing.

Until 1b ships, a mutating MCP tool appears in `Toolbox.skipped` with a reason,
which `systemPrompt` (line 1154) already surfaces to the model. The agent says
"I could not do that", which is the honest outcome.

## Data model

Three new tables in agent-service. Migrations continue from `V5__python_runtime.sql`.

### `V6__mcp_servers.sql`

```sql
CREATE TABLE mcp_servers (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  tenant_id       VARCHAR(64)  NULL,        -- NULL = provider-authored, all tenants
  project_id      BIGINT       NULL,        -- NULL = tenant-wide
  name            VARCHAR(128) NOT NULL,
  transport       VARCHAR(16)  NOT NULL,    -- HTTP | STDIO
  endpoint        TEXT         NOT NULL,    -- URL, or the command for STDIO
  auth_kind       VARCHAR(32)  NOT NULL,    -- NONE | BEARER | HEADER | OAUTH
  auth_secret     TEXT         NULL,        -- encrypted, same scheme as model creds
  enabled         BOOLEAN      NOT NULL DEFAULT TRUE,
  ...
);

CREATE TABLE mcp_tools (            -- the discovery cache AND the curation record
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  server_id       BIGINT       NOT NULL,
  tool_name       VARCHAR(128) NOT NULL,    -- the server's own name
  description     TEXT         NULL,
  input_schema    JSON         NULL,
  mutating        BOOLEAN      NOT NULL DEFAULT TRUE,   -- see below
  classified_by   VARCHAR(128) NULL,
  classified_at   TIMESTAMP    NULL,
  discovered_at   TIMESTAMP    NOT NULL,
  UNIQUE KEY (server_id, tool_name)
);
```

`STDIO` transport is listed for completeness and should be **HTTP-only in 1a**.
A stdio server means agent-service spawning a subprocess per call, which is a
process-lifecycle and sandboxing problem that has nothing to do with MCP and
should not be acquired alongside it.

### The `mutating` column is the centre of gravity

**MCP does not tell you whether a tool changes state.** The protocol has no such
field. `annotations.readOnlyHint` exists in newer revisions but is advisory,
optional, and supplied by the server — that is, by the party we are not trusting.

So classification is ours, and it is a human act:

- Discovery writes every tool with `mutating = TRUE`.
- A provider or tenant admin marks the read-only ones, through the UI, and that
  is recorded with who and when.
- Re-discovery **never downgrades** an existing row. A server that renames or
  re-describes a tool gets a *new* row at the default, not an inherited
  classification.
- A tool whose `input_schema` changed since classification is reset to
  `mutating = TRUE` and must be re-marked. The schema is part of what was
  classified.

This is deliberately more friction than reading a hint off the wire. The
alternative is that a server operator's typo decides whether a diagnosing agent
is shown a delete tool.

### `V7__toolsets.sql`

A toolset is the sealed, versioned bundle an agent references instead of raw ids.

```sql
CREATE TABLE toolsets (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  ref         VARCHAR(128) NOT NULL,        -- e.g. "aws.read_only_inventory"
  version     VARCHAR(32)  NOT NULL,
  tenant_id   VARCHAR(64)  NULL,            -- NULL = provider-authored
  name        VARCHAR(128) NOT NULL,
  description TEXT         NULL,
  entries     JSON         NOT NULL,        -- [{kind, ...}] — see below
  UNIQUE KEY (ref, version, tenant_id)
);
```

`entries` holds the three kinds behind one shape:

```json
[
  {"kind": "JOB",      "id": 14,                          "mutating": false},
  {"kind": "WORKFLOW", "id": 3,                           "mutating": true},
  {"kind": "MCP",      "server": 2, "tool": "list_alerts", "mutating": false}
]
```

An agent's `tools` column keeps its current shape and gains one more entry type,
`{"kind":"TOOLSET","ref":"aws.read_only_inventory","version":"1.0.0"}`, expanded
during `build`. Existing agents are untouched — this is additive, and the V1
parse path in `AgentToolbox.parse` (line 247) already ignores what it does not
recognise.

Toolsets also fix a real existing fragility that is unrelated to MCP: an
allow-list today is bare ids, and ids go stale between the moment an agent is
saved and the moment it runs. That is why `build` re-validates everything. A
versioned toolset makes the reference nameable and the staleness diagnosable.

## Changes to agent-service

### `AgentToolbox.Tool`

```java
public record Tool(String name, String type, Long targetId, String targetName,
                   boolean mutating, String remoteTool) { }
```

One added field, null for JOB and WORKFLOW. `targetId` carries the server id for
MCP; `remoteTool` carries the server's own tool name. Splitting them matters
because the model-facing name must stay collision-proof — the existing scheme
gives `mcp_2_list_alerts`, unique by construction, with the human name in the
description where the model actually reads it.

### `AgentToolbox.build`

A third branch, `addMcp`, structurally identical to `addJob`:

- Load the server; refuse unless enabled and in scope for this tenant *and*
  project. Same fail-closed rule as `ToolTargetClient`: absent, disabled or
  unreachable is a refusal with a `skipped` reason, never an assumption.
- Load the `mcp_tools` row. Missing → `skipped` ("not yet discovered").
- `mutating && phase1a` → `skipped` ("this tool changes state and cannot be run
  from an agent yet").
- Otherwise emit a `ToolSpec` whose schema is the server's `input_schema`
  **verbatim**. MCP `inputSchema` is already JSON Schema, so unlike Dify's field
  types (`schemaFor`, line 202) there is nothing to translate and nothing to get
  wrong.

Discovery itself (`tools/list`) is **not** on the run path. It is a scheduled
refresh plus an explicit "rescan" button, writing `mcp_tools`. A run that
depended on a live `tools/list` would fail whenever the server was slow, and
would change an agent's capabilities without anyone deciding to.

### `AgentRunService.invoke`

```java
if ("MCP".equals(tool.type())) {
    return invokeMcp(run, tool, call, began);   // synchronous; no dispatch, no watch
}
// unchanged from here
```

`invokeMcp` calls `tools/call`, then records exactly the step rows the automation
path records — `TOOL_CALL` before, `TOOL_RESULT` after, with `durationMs` and the
`error` flag — so the evidence ledger, the run timeline UI and the audit trail
need no changes at all. An MCP failure is a tool error the model can recover
from, never a run failure, matching the existing treatment of a core refusal
(line 811).

New config under `autoops.agent.loop`: `mcp-timeout`, seconds-scale. Reusing
`tool-timeout` would be wrong — that one is sized for automations and is measured
in minutes.

### Result size

An MCP server can return a great deal of text, and the transcript is re-sent on
every reduce. Cap the content written into a `ToolResult`, keep the full payload
in the `agent_run_steps` row, and say in the truncated text that it was
truncated and where the rest is. Uncapped, one chatty inventory tool exhausts a
context window and the run dies several steps later for no visible reason.

## What does not change

**agent-runtime: zero lines.** It receives
`ToolSpecWire{name, description, input_schema, mutating}` and has no concept of
where a tool came from. MCP tools arrive as ordinary offered tools, get narrowed
by `PHASE_ACCESS` like everything else, and produce ordinary evidence ids.

That is the payoff of the split that already exists. It is worth stating plainly
because it is the strongest argument for putting MCP in Java: the reasoning half
stays disposable, and nothing that can reach a customer's infrastructure moves
into the process that does the thinking.

Also unchanged: approvals, the audit trail, `SubscriptionGate`, the step budget,
the evidence re-check in `finishFromRuntime` (line 577).

## Phase 1b — mutating MCP

Route it through core-service as a new automation target type so it inherits the
approvals inbox rather than growing a second one.

- core-service gains an MCP dispatch step; `automations.dispatch` accepts
  `type = "MCP"` and returns a run id or an approval id exactly as it does now.
- `invoke` needs no MCP branch for mutating tools — they take the existing path
  untouched.
- The approval card must show the server, the tool and the resolved arguments.
  An approver deciding on `mcp_2_terminate_instance` with the arguments hidden is
  not approving anything meaningful.

The open question for 1b is **idempotency**. Approving a job re-runs a saved
definition. Approving an MCP call re-issues a call that may have already had an
effect if the first attempt timed out ambiguously. Jobs and workflows have the
same hazard in principle, but core-service's run row makes it visible. Worth
resolving before 1b, not before 1a.

## Risks

- **Prompt injection through tool results.** An MCP server returns text straight
  into the model's context. A malicious or compromised server can attempt to
  redirect the agent. The allow-list is the mitigation that already holds — the
  agent cannot reach a tool it was not granted, no matter what a result says —
  but read-only phases having no destructive tools *at all* is what makes this
  survivable rather than merely unlikely. Do not weaken phase narrowing for MCP.
- **A server is a network dependency on the run path.** `tools/call` is
  synchronous inside the loop. Timeout short, fail as a tool error, never as a
  run failure.
- **Credential scope.** An MCP server credential is usually far broader than a
  single automation's. A server marked read-only whose credential can write is a
  read-only tool in name only. The UI should say so where the credential is
  entered.

## Work breakdown

| # | Item | Size |
|---|---|---|
| 1 | `V6` migration, entities, repositories | S |
| 2 | MCP client (HTTP transport, `tools/list`, `tools/call`, auth) | M |
| 3 | Discovery job + rescan endpoint | S |
| 4 | `AgentToolbox.addMcp` + the `Tool` field + skip reasons | S |
| 5 | `AgentRunService.invokeMcp` + truncation + timeout config | M |
| 6 | Provider UI: servers, discovery, the read-only classification screen | M |
| 7 | `V7` toolsets + `TOOLSET` expansion in `build` | M |
| 8 | Toolset authoring UI, agent builder references toolsets | M |
| 9 | Tests: fail-closed scope, classification never downgrades, an unclassified tool is never offered, truncation | M |

1–6 is phase 1a and is the shippable unit. 7–8 can follow independently; nothing
in 1a depends on toolsets existing.

## Open

- Whether tenants may register their own MCP servers, or only the provider.
  The sealed-catalogue model argues provider-only at first, with tenant-supplied
  *credentials* against provider-defined servers.
- OAuth-bearing MCP servers need a token refresh path. `auth_kind = OAUTH` is in
  the schema but should be out of scope for 1a.
- Whether a `VERIFY` phase becomes mandatory once mutating MCP lands. The
  runtime README already flags this as a deliberate next step.
