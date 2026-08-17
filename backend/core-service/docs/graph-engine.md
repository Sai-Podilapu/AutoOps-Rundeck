# Graph execution engine — design

Status: **proposed**, not built. Target: turn the workflow designer's canvas
into a real data-flow engine (n8n-style) instead of the linear step runner it
drives today.

Audience: whoever implements it. This is meant to be enough to start from.

---

## 1. Where we are

`ExecutionEngine.execute()` walks a run's steps in a `for` loop
(`execution/ExecutionEngine.java:99`). `parseSteps()` (same file, line 218)
reads `nodes[]` out of the workflow definition **in array order** and hands
each entry to the `StepExecutor`. The `edges[]` the designer draws are stored
in the definition and never read.

Consequences, all structural:

- **No graph.** A workflow is a sequential script that happens to be drawn as
  boxes and arrows. Two parallel branches on the canvas run one after another.
- **No data flow.** A node cannot see what the node before it produced. Output
  goes into a text log, not into the next node.
- **No per-node record.** A run's entire result is `runs.log` (one
  `MEDIUMTEXT`) plus `step_total` / `step_completed`. There is nowhere to show
  "what did node 3 receive and emit", which is the single most useful thing an
  n8n-style UI does.

What is already right and must survive the rewrite:

- reload-before-write so a concurrent cancel is never clobbered (lines 114,
  134 — this discipline is load-bearing, keep it)
- per-step `retries` with cancel-wins-over-retry, and `continueOnError`
- terminal metrics (`core_runs_total`) and failure notifications
- definition snapshotting onto the run, so history survives edits and deletes

The rewrite is narrower than it first looks: it replaces the loop and the
result model, not the lifecycle.

---

## 2. Goals / non-goals

**Goals**

1. Execute the graph the user drew: branches, merges, parallel paths, loops.
2. Pass data between nodes as JSON item arrays.
3. Record per-node input, output, status and timing, so the UI can show a run
   node by node and re-run from a chosen node.
4. Change nothing for existing workflows and jobs on day one.

**Non-goals (for this document)**

- The node catalogue. This designs the engine; integration nodes are separate
  work and separately estimated.
- The designer UI. It consumes what is designed here.
- Remote agents. The `NodeExecutor` seam is where they will attach, and that
  is all this document says about them.

---

## 3. Definition schema

```json
{
  "nodes": [
    { "key": "n1", "type": "trigger.manual", "name": "Start", "params": {} },
    { "key": "n2", "type": "http.request", "name": "Fetch user",
      "params": { "url": "={{ $json.baseUrl }}/users/{{ $json.id }}" },
      "retries": 2, "continueOnError": false },
    { "key": "n3", "type": "core.if", "name": "Active?",
      "params": { "left": "={{ $json.status }}", "op": "equals", "right": "active" } }
  ],
  "edges": [
    { "from": "n1", "fromPort": "main",  "to": "n2", "toPort": "main" },
    { "from": "n2", "fromPort": "main",  "to": "n3", "toPort": "main" },
    { "from": "n3", "fromPort": "true",  "to": "n4", "toPort": "main" },
    { "from": "n3", "fromPort": "false", "to": "n5", "toPort": "main" }
  ],
  "settings": { "maxItemsPerNode": 1000, "maxRunSeconds": 900, "maxParallel": 4 }
}
```

### Ports are load-bearing

`core.if` emits on `true` / `false`, `core.switch` on `case0..caseN`,
`core.merge` accepts `input0` / `input1`. Branching cannot be expressed without
them, and adding them later means migrating every stored definition. Put them
in from the first commit even if the designer does not emit them yet.

### `key` vs `type` vs `name`

- `key` — stable identifier within the workflow, referenced by edges. Never
  reused, never renamed.
- `type` — the node type id (`http.request`, `core.if`, `terraform`).
- `name` — the user's label, referenced from expressions (`$node["Fetch user"]`).

**`type` must keep the current spelling.** `WorkflowComplexity` (approvals
gating) and the governance policies read `nodes[].type`, falling back to `id`.
Keep that field and that fallback, or admin sign-off silently stops firing on
risky workflows. Note the existing wart while you are here: the designer emits
`k8s` and jobs emit `kubernetes` for the same thing — the node-type registry is
the right place to finally unify them.

### Backward compatibility — the migration trick

**When `edges` is missing or empty, synthesise a linear chain from array
order.** Every existing workflow and every job then runs on the new engine with
byte-identical semantics, before the designer emits a single edge.

This is what makes the change shippable: phase 1 goes to production dark,
proves the engine against real traffic, and there is no big-bang cutover.

---

## 4. Schema changes

```sql
-- V19__graph_execution.sql
ALTER TABLE runs
    ADD COLUMN execution_mode ENUM('SEQUENCE','GRAPH') NOT NULL DEFAULT 'SEQUENCE' AFTER definition,
    ADD COLUMN nodes_total    INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN nodes_finished INT UNSIGNED NOT NULL DEFAULT 0;

CREATE TABLE run_node_executions (
    id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    run_id          BIGINT UNSIGNED NOT NULL,
    node_key        VARCHAR(128)    NOT NULL,
    node_name       VARCHAR(128)    NOT NULL,
    node_type       VARCHAR(64)     NOT NULL,
    iteration       INT UNSIGNED    NOT NULL DEFAULT 0,  -- loop / re-entry counter
    attempt         INT UNSIGNED    NOT NULL DEFAULT 0,
    status          ENUM('PENDING','RUNNING','SUCCEEDED','FAILED','SKIPPED','CANCELED') NOT NULL,
    output_port     VARCHAR(64)     NULL,                -- which port actually fired
    input_items     MEDIUMTEXT      NULL,                -- JSON array, capped
    output_items    MEDIUMTEXT      NULL,                -- JSON array, capped
    items_truncated TINYINT(1)      NOT NULL DEFAULT 0,
    log             MEDIUMTEXT      NULL,
    error           VARCHAR(512)    NULL,
    started_at      TIMESTAMP(6)    NULL,
    finished_at     TIMESTAMP(6)    NULL,
    duration_ms     BIGINT UNSIGNED NULL,
    PRIMARY KEY (id),
    KEY idx_rne_run (run_id, node_key, iteration),
    CONSTRAINT fk_rne_run FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
```

Two things to get right now rather than later:

- **Keep writing `runs.log`.** The Executions page renders it. Dual-write the
  rendered log alongside node records through the transition, then retire it
  once the UI reads node records.
- **Retention.** The cascade covers the plan-bounded history sweep, but node
  rows multiply run rows by 10–50×. Re-check the retention job's cost before
  this meets a busy tenant, and consider dropping `input_items` /
  `output_items` on runs older than a few days while keeping the status rows.

---

## 5. Execution algorithm

Not a plain topological sort. The semantics are **data-driven readiness** — a
node runs when every input it is connected to has been resolved, where
"resolved" means the upstream either produced data on that port or was skipped.
The difference shows up the first time a user draws an `IF`.

```
validate(graph)                       // at save time, not run time
ready ← nodes with no incoming edges  // triggers, or the manual start

while ready is not empty and not cancelled:
    batch ← take up to settings.maxParallel from ready
    execute batch concurrently:
        inputs  ← concat(output_items of upstream edges feeding this node's ports)
        params  ← evaluateExpressions(node.params, inputs, context)
        outcome ← nodeExecutor.execute(invocation)   // retries + continueOnError here
        persist run_node_executions row
    for each finished node:
        mark descendants on non-fired ports SKIPPED, transitively,
            unless a descendant still has another live (unresolved) input
        for each descendant on the fired port:
            if all its incoming edges are resolved: ready ← ready + descendant

finish(run, FAILED if any node failed without continueOnError else SUCCEEDED)
```

### Node semantics

| Type | Behaviour |
|---|---|
| `core.if` / `core.switch` | Evaluated per item; each item leaves on exactly one port |
| `core.merge` | `waitAll` (barrier, joins branches) or `passThrough` (fires per arriving input) |
| `core.splitInBatches` | Re-enters its body with the next batch; `iteration` tracks visits; bounded by `maxIterations` |
| `core.setData` / `core.noOp` | Pure data shaping — no executor dispatch, no container round-trip |

### Concurrency

`settings.maxParallel` (default 4) must stay **below** job-service's step-user
pool size (`STEP_SANDBOX_USERS`, default 8), or concurrent runs will start
failing on sandbox lease timeouts. These two numbers are related; document the
relationship where both are configured rather than letting them drift apart.

---

## 6. Interfaces

```java
public interface NodeExecutor {

    record NodeInvocation(String nodeKey, String nodeName, String type,
                          JsonNode params,          // expressions already resolved
                          List<JsonNode> inputItems,
                          int attempt,
                          ExecutionContext context) { }

    record NodeOutcome(boolean success, String port,
                       List<JsonNode> outputItems,
                       String log, String error, long durationMs) { }

    NodeOutcome execute(String tenantId, Long projectId, NodeInvocation invocation);
}
```

Dispatch splits by node kind:

- **Shell-flavoured types** (`command`, `script`, `pyscript`, `terraform`,
  `kubernetes`, `awslambda`, `azurefn`, `ssh`) → `JobServiceStepExecutor`,
  unchanged. It already resolves the step's cloud integration, decrypts it and
  ships the bundle; none of that logic moves.
- **Pure types** (`core.if`, `core.merge`, `core.setData`, `http.request`) →
  executed in-process in core-service. They never reach job-service. Paying a
  container round-trip and a sandbox lease for an `IF` would be absurd, and the
  sandbox exists for untrusted *code*, which these are not.

Remote agents, when they arrive, are a third dispatch target behind the same
interface, selected by the node's `nodeId` (the `nodes` inventory record).

---

## 7. Expressions

Evaluated in **core-service, before dispatch**, so job-service continues to
receive literal values and its security model is untouched.

- **Engine**: GraalJS with `allowHostAccess(NONE)`, no host class lookup, a
  statement limit, and a 500 ms ceiling per evaluation.
- **Convention**: a value is an expression when it starts with `=` (n8n's
  convention — copying it means your users' muscle memory transfers).
- **Context**: `$json` (current item), `$items("Node Name")`,
  `$node["Name"].json`, `$run.id`, `$vars`, `$now`.
- **Hard rule: credentials are never in the expression context.** They attach
  at dispatch, exactly as today. An expression able to read a decrypted AWS key
  would undo the isolation work in job-service in one line.

---

## 8. Validation at save time

`WorkflowService` already rejects a bad cron with `400 invalid_schedule`. Give
graphs the same treatment, so a run never starts on a graph that cannot finish:

| Rejected | Error code |
|---|---|
| Unknown node type | `unknown_node_type` |
| Edge referencing a missing node or port | `invalid_edge` |
| Cycle not routed through a loop node | `cyclic_graph` |
| More than one trigger node | `multiple_triggers` |
| Node count over the plan's `MAX_NODES` | `quota_exceeded` (existing) |

---

## 9. Cancellation, retry, resume

- **Cancel** — check `cancel_requested` before dispatching each batch and
  between loop iterations, with the same fresh-read-before-write pattern the
  current engine uses. In-flight nodes finish; nothing new starts.
- **Retry from node** — because per-node input and output are persisted, a
  re-run can seed from a previous run's node outputs and start at a chosen
  node. This is the feature that makes the designer feel like n8n, and it is
  free once the schema above exists.
- **Test a single node** — run one node against pinned input data, persisting
  nothing to the run history.

---

## 10. Limits to set before launch, not after

| Limit | Suggested start |
|---|---|
| Items per node output | 1000 |
| Bytes stored per node execution | 256 KB, then truncate and set `items_truncated` |
| Loop iterations | 100 |
| Parallel branches | 4 (see §5) |
| Total run wall-clock | 900 s |

Truncate rather than fail: a run that dies at item 1001 is worse than a run
that completes with a flagged, shortened record. This set of numbers is what
decides whether large runs stay usable — n8n's in-memory item model is exactly
where it falls over, and we get to not repeat that.

---

## 11. Phasing

| Step | Deliverable | Days |
|---|---|---|
| 1a | Schema + graph executor behind `EXECUTION_GRAPH=true`; edges synthesised when absent. **No behaviour change** | 6–8 |
| 1b | Ports; `IF` / `Switch` / `Merge` / `SplitInBatches`; per-node records exposed on `GET /api/runs/{id}` | 6–8 |
| 1c | Designer emits edges and ports; run inspector shows per-node input/output | frontend, parallel |
| 2 | Expression engine + `core.setData` | 8–12 |
| 3 | `http.request` node + reusable auth profiles | 10–15 |

Phase 1a is self-contained, ships dark, and de-risks everything after it.

---

## 12. Open decisions

1. **Do jobs move onto the graph engine too?** One engine and one set of
   semantics means less code — the recommendation — but job runs would then
   render from node records instead of the log string.
2. **Item and byte caps** — the table in §10 is a starting proposal, not a
   measured number.
3. **Loops** — an explicit `SplitInBatches` node (n8n's model; keeps the graph
   acyclic and validation simple) versus real cycles in the graph. The explicit
   node is recommended.
