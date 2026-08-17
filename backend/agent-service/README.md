# agent-service

AI agents (port **8087**, MySQL `autoops_agent`). Boot 3.4.2 / Java 21. Every row is tenant-scoped by the JWT `tenantId` claim — never a header.

Split out of core-service. The console's paths, payloads and error codes are unchanged (`agent_not_found`, `agent_exists`, `invalid_tools`, `unknown_tool_target`, …) — the gateway points `/api/agents/**` and `/api/projects/{id}/agents` here instead.

## What an agent is

A named operator inside a project: a persona (`instructions`), a `model` id, and — the part that decides what it can actually do — a **closed allow-list of `tools`**: the project's own workflows and jobs it is permitted to operate, stored as `[{"type":"JOB|WORKFLOW","id":N}]`.

Agents now **run**. See "The loop" below.

## Endpoints

- `GET/POST /api/projects/{projectId}/agents`
- `GET/PUT/DELETE /api/agents/{id}`, `POST /api/agents/{id}/enable|disable`
- `POST /api/agents/{id}/runs` → **202** with the run in `PENDING`; the answer does not exist yet, so the console polls for it
- `GET /api/agents/{id}/runs` → the agent's run history
- `GET /api/agent-runs/{runId}` → one run plus every step, in order
- `POST /api/agent-runs/{runId}/cancel`

There is deliberately **no approve endpoint here**. An agent's approval is an ordinary approval in the ordinary inbox, decided on the Approvals screen. A second approval surface for agents would be a second place to look on the day something ran that should not have.

Internal (shared-secret `X-Internal-Token`, never routed by the gateway):

- `GET /internal/agents/count?tenantId=` → the agent half of the shared automation budget. One endpoint, because one fact about agents matters outside this service. It returns a count, never agent content.

## The loop

Ask the model. If it asked for a tool, run the tool and ask again. Stop when it stops, when the step budget runs out, or when a tool needs a human.

Six adapters cover eleven vendors (`loop/`): Anthropic; the OpenAI wire format shared by OpenAI, Mistral, Groq, DeepSeek, xAI and Ollama; Azure OpenAI; Bedrock via Converse; Gemini; and Huawei against a ModelArts inference endpoint. `ChatModels` **refuses** an unknown vendor rather than falling back — an agent configured for Bedrock that quietly ran on OpenAI would bill the wrong account and send the tenant's data somewhere they did not choose.

**It is not a while-loop in memory.** A run can pause for a human and not move again for two days, so the loop's state is the `transcript` column, rewritten after every step; resuming is reading it back. `TranscriptCodec` writes that format by hand rather than with Jackson polymorphism, because a parked run makes it a compatibility surface — a renamed record must not silently strand every run in the queue.

**Credentials never live here.** core-service holds the only encryption key and this service holds the only vendor clients, so `ModelCredentialsClient` fetches a decrypted key per run, per model, and caches nothing. A cached credential would survive a rotation the tenant believes took effect and outlive a provider they just disabled.

**Tools are the allow-list, resolved at run time.** `AgentToolbox` builds the specs the model is shown and is the only thing that can turn a returned tool name back into a target. A name that was never granted is a tool error the model is told about, never a lookup that goes and finds something. Entries are re-validated against their owning service on every run, because the list holds *ids* and a job can be deleted or moved between the save and the run.

A Dify-backed workflow's published input form becomes the tool's JSON Schema, so an agent can actually fill in the hostname rather than just press a button. A workflow whose Dify key is missing or revoked is left **out** of the model's list and named in the system prompt as unavailable — a tool that fails on every call burns steps and teaches the model nothing.

### Approvals

core-service decides whether a target needs a human (`POST /internal/agent/dispatch` answers `RUN` or `APPROVAL`); this service never re-derives that rule. Re-implementing it here would create a second copy, and the day it drifts an agent runs unattended something the console swore needed a person.

When a human is needed the run parks in `AWAITING_APPROVAL` with the approval id and the id of the tool call that raised it. An admin approving it in the normal inbox **starts the run** — and the loop then attaches to *that* run rather than starting a second one. `AgentApprovalPoller` picks the verdict up; a poller rather than a callback, because core cannot reach a specific paused loop and a run parked before the last restart has no loop to call back into.

A model can ask for several tools in one turn, and vendors require all of them answered together. If the second of three needs approval, the transcript parks holding the results collected so far, and the resume path derives what is still outstanding by comparing the assistant turn's tool calls against the results already recorded. No extra bookkeeping column, and no result emitted twice.

### Bounds (`autoops.agent.loop.*`)

| | default | why |
|---|---|---|
| `max-steps` | 12 | copied onto each run, so tightening it never kills a run in flight |
| `max-tokens` | 4096 | per model call |
| `tool-timeout` | 10m | stops **watching**, never cancels — the model is told the job is still running, which is true |
| `tool-poll-interval` | 3s | |
| `approval-timeout` | 2d | covers a weekend; measured from run start, so it expires slightly early |
| `approval-poll-interval` | 15s | fast enough that nobody notices after clicking Approve |

Runs execute on a small bounded pool (`AgentLoopConfig`): 2–4 threads, caller-runs when full. Sized for restraint, not throughput — each run holds a thread for minutes and spends the tenant's money.

## The allow-list is the security boundary — and it now spans three services

An agent's power is exactly its tools list, so every entry is re-resolved against the **owning project** on every write. After the split the answers live elsewhere: **jobs** come from core-service, **workflows** from workflow-service.

`ToolTargetClient` **fails closed** on all of it. A target is accepted only when its owning service positively confirms it exists, belongs to this tenant, and sits in the agent's own project. A 404, a timeout or a service that is down are all refusals (`unknown_tool_target`, or 503 `tool_validation_unavailable`). Assume-good on an outage would make that outage the moment an agent gets pointed at something nobody verified.

Two deliberate exceptions, both on **read** paths:
- resolving tool **names** for display degrades to "Deleted job #31 / unavailable" rather than refusing to list agents;
- the **workflow count** for the shared budget counts 0 when workflow-service is unreachable, mirroring workflow-service's own policy for the agent half.

A tool whose target is later deleted comes back `available: false` with its id — an agent pointing at something that no longer exists is a configuration problem its owner has to see.

## Other invariants carried over from the monolith

- `tool_count` is derived **server-side** from the stored list; a client-supplied count would be a way around the validation.
- Agents share **one MAX_AUTOMATIONS budget** with workflows — an autonomous operator is an automation, and a separate bucket would silently double every plan's allowance.
- Mutations are audited into **core-service's single trail** (`AGENT_CREATED|UPDATED|DELETED|ENABLED|DISABLED`) via `/internal/audit`, so agent events sit next to the project and job events they relate to. Best-effort: recording never breaks the mutation it documents.
- `POST /api/agents/{id}/disable` is the kill switch.

## Configuration

`SERVER_PORT`, `DB_*`, `AUTH_JWKS_URI`, `JWT_ISSUER`, `SUBSCRIPTION_SERVICE_URL`, `ENTITLEMENT_FAIL_OPEN`, `CORE_SERVICE_URL`, `WORKFLOW_SERVICE_URL`, and the shared secrets `CORE_INTERNAL_TOKEN` / `WORKFLOW_INTERNAL_TOKEN` (presented to peers) and `AGENT_INTERNAL_TOKEN` (required on this service's own `/internal/**`).

## Migrating an existing deployment

The table moved whole, columns unchanged:

```sql
INSERT INTO autoops_agent.agents SELECT * FROM autoops_core.agents;
```

## Tests

`mvn test` — H2 with the peers mocked.

- `AgentServiceTest` — allow-list validation and normalization, refusal of out-of-project / unknown / unverifiable targets, the shared automation budget, tenant isolation, partial updates, the dangling-target read.
- `AgentToolboxTest` — the enforcement point: a name that was never granted resolves to nothing, a target that moved out of the project is dropped, a Dify form becomes the tool schema, a corrupt allow-list grants nothing.
- `TranscriptCodecTest` — round-trips every message kind including a partially answered turn, keeps the tool-error flag, and **refuses** a corrupt transcript rather than resuming with the middle of the conversation missing.
