# agent-runtime

The reasoning half of AutoOps agents. Python 3.12, FastAPI, LangGraph.

It is a **stateless reducer**: `(state, event) → state'`. agent-service sends the
whole run state on every call and stores whatever comes back; this service keeps
nothing between requests — no database, no cache, no session. Two consecutive
calls can land on two different instances, or on the same instance three days
apart across a redeploy, and neither case is special-cased because neither case
is different.

```
agent-service (Java, control plane)        agent-runtime (this)
──────────────────────────────────         ────────────────────
CRUD, catalog, rollout, entitlements
tenancy, security, Flyway
agent_runs / agent_run_steps
resolves model credentials      ─────────► POST /v1/reduce
drives the loop                 ◄───────── directive: CALL_TOOLS | FINISH | FAIL
executes tools, parks on approvals
writes every audit row                     prompts, phases, context assembly,
                                           tool narrowing, error compaction,
                                           the evidence ledger
```

**The split is not arbitrary.** agent-service owns everything a loop must not
lose — transaction boundaries, the approvals inbox, the audit trail, the tenant
check. This service owns everything that benefits from being disposable. A tool
only ever runs because Java ran it; nothing here can reach a customer's
infrastructure.

## Why an agent is more than a persona here

An agent in the old model was `{instructions, model, tools[]}` driving one
undifferentiated ReAct loop — which is what every competitor ships. Here an
agent is a **graph of phases**, each with its own prompt and its own narrowed
toolbox:

| Phase | Job | Tools it can see |
|---|---|---|
| `TRIAGE` | decide what the run needs; refuse work the tools cannot do | none |
| `GATHER` | collect observations | **read-only only** |
| `HYPOTHESIZE` | conclude, from the ledger | none |
| `PLAN` | propose actions, with blast radius and rollback | none |
| `GATE` | emit the action; Java's approvals take over | mutating |
| `ACT` | absorb the human's verdict | mutating |
| `VERIFY` | prove the state actually moved | read-only |
| `REPORT` | the answer, evidence-enforced | none |

Two consequences that a single loop cannot give you:

- **`GATHER` is never *shown* a destructive tool.** Not instructed to avoid one
  — never sent one. A model that can see a delete tool while diagnosing will
  eventually reach for it, because it is right there and looks like progress.
- **`HYPOTHESIZE` has no tools at all**, so the only way to finish is to say
  what the numbers mean. A model that can still collect will keep collecting.

## The evidence ledger

Every tool result agent-service records produces an `agent_run_steps` row, and
**that row's primary key is the citation**. The ledger is an index over rows the
control plane was writing anyway, which is why it needs no table of its own.

`REPORT` must mark every factual claim `[e:<id>]`. `evidence.audit` then checks
the draft:

- a citation to an id this run never issued is caught **exactly**;
- a claim-shaped sentence with no citation is caught **heuristically**.

One repair prompt, then the report ships either way — carrying a visible
`UNVERIFIED` banner naming the lines it could not substantiate. It never fails
the run: a flagged report during an incident is worth more than no report.
agent-service repeats the exact check independently against the run's own step
ids, so a fabricated id cannot survive even if this service's check is wrong.

The heuristic errs toward silence. It exempts hedges, recommendations and
"this was not measured" — see the note in `evidence.py`, and the golden case
that put it there.

## Layout

```
agent_runtime/
  app/
    main.py       FastAPI: /v1/reduce, /v1/agents, /v1/vendors, /health
    reduce.py     the reducer — the whole service in one function
    state.py      the wire contract; STATE_VERSION lives here
    models.py     LangChain chat models per vendor (mirrors Java's ModelVendor)
    toolbox.py    per-phase tool narrowing
    evidence.py   the ledger and its two checks
  graph/
    prompts.py    every prompt, versioned (Factor 2)
    phases.py     the phase kit
    kit.py        phases -> a compiled LangGraph
    crews.py      CrewAI, for the hypothesize phase of hard triage only
  agents/
    aws/public_exposure_auditor.py     RD-149/145/137 — correlates three audits
    aws/cost_anomaly_investigator.py   RD-141/142/136 — explains a bill movement
    linux/server_health_check.py       RD-079 — SSH; needs a key volume (see gaps)
    generic/single_phase.py            the legacy-compatibility loop
evals/            golden cases + the replay harness
```

### The shipped agents

| Agent | Tools | Why an agent rather than three reports |
|---|---|---|
| `aws.public_exposure_auditor` | S3 public access · IAM key age · security group ingress | The finding is in the *intersection* — a public bucket reachable through an open port with a stale key is a chain, not three lists |
| `aws.cost_anomaly_investigator` | Cost Explorer delta · idle volumes & EIPs · S3 storage | Cost Explorer says spend rose; only correlation says *which resources* explain it |

Both are read-only, four-phase (`TRIAGE → GATHER → HYPOTHESIZE → REPORT`), and
collect all their tools in **one** turn before reasoning with the tools removed.

## Agents are Python modules, and that seals them properly

A rolled-out JSON agent physically copies its `instructions` into the customer's
own database row, protected only by no API exposing it. Anyone with a database
credential has the product.

Here, an agent module exports an `AgentSpec` with a **public `Manifest`** and a
**private persona + graph**. Only the manifest is published; the customer's row
holds a reference:

```json
{"kind": "PYTHON", "ref": "linux.server_health_check", "version": "1.0.0", ...}
```

`Manifest.to_json` structurally cannot emit a persona, and a test asserts it.
The cost is real and worth naming: a new agent can no longer be rolled out
independently of a deploy — shipping one means shipping this image.

### Adding an agent

1. Write `agent_runtime/agents/<domain>/<name>.py` exporting `AGENT: AgentSpec`.
2. Register it in `agent_runtime/agents/__init__.py` — one import, one line.
   Deliberately explicit, so `git log` on that file is the catalog's deployment
   history.
3. Mark each `ToolRef` as read-only where it is. **Unmarked means mutating**, on
   both sides of the wire.
4. `pytest`, then publish:
   `python backend/agent-service/agents/_schema/publish.py --runtime http://localhost:8089 --dry-run`

## Running it

```bash
python -m venv .venv && .venv/bin/pip install -e ".[dev]"
uvicorn agent_runtime.app.main:app --port 8089 --reload

pytest                          # unit tests + golden cases
python -m evals.replay check    # golden cases alone, with a readable diff
```

`GET /health` is unauthenticated (compose's healthcheck holds no secret) and
reports the agent registry, prompt version and state version — the fastest way
to tell whether the deployment is the one you think it is.

Everything under `/v1` requires `X-Internal-Token`. api-gateway does not route
here at all; the only caller is agent-service.

## Evals

`evals/` replays recorded runs. Two modes, answering different questions:

- **`check`** — the regression gate. Replays golden cases with their recorded
  model replies, so nothing varies except our own code. Free, deterministic, runs
  in `pytest`. A prompt edit that changes how a real recorded run behaves fails
  the build.
- **`compare`** — the judgement call. Re-reduces a real run's state (straight out
  of `agent_runs.transcript`) against a live model, and prints what changed.
  Costs tokens, gives a different answer every time, and is therefore a manual
  act rather than a test.

## Known gaps

- **`linux.server_health_check` cannot authenticate in the compose stack.**
  Its automation is an `ssh` step, and `SshRunner` needs key-based auth
  provisioned at `/home/autoops/.ssh` — which `docker-compose.yml` does not
  mount. The agent and its workflow are correct; the transport is missing. The
  two AWS agents were built against `pyscript`/boto3 for exactly this reason.
- **Huawei has no adapter here.** Its ModelArts endpoint has no LangChain
  binding, so agent-service keeps Huawei-backed agents on its own Java loop
  rather than letting them arrive and fail. `GET /v1/vendors` publishes what
  this build can serve so the two sides cannot disagree.
- **The Dockerfile's base image is pinned by tag, not digest**, unlike every
  other service here. A digest must be read from a real `docker pull` — an
  invented one fails the build outright rather than degrading to the tag. The
  command to get it is in the Dockerfile.
- **`VERIFY` is available but not mandatory.** No agent currently declares it.
  Making a run that cannot prove its effect report `UNVERIFIED` rather than
  `SUCCEEDED` is a deliberate next step, not an oversight.
- **CrewAI is an optional extra and is NOT in the default image.** `crewai`
  requires `crewai-tools`, which pulls a browser-automation stack, `pytube` and
  `youtube-transcript-api` — a large dependency surface to acquire, in a service
  that reasons about production infrastructure, for a feature no shipped agent
  uses yet. `graph/crews.py` imports it lazily and `panel()` falls back to the
  ordinary single-model `hypothesize` node when it is missing, so every agent
  runs correctly without it. An image that serves a crew-backed agent installs
  `.[crew]`; the fallback is covered by `tests/test_crews.py`.
