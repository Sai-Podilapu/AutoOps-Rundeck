# AutoOps Rundeck Service

The adapter in front of **the execution engine** (port **8090**, Boot 3.4.2 /
Java 21). Rundeck replaces job-service: every step, in every project, for every
tenant, runs on the Rundeck AutoOps operates itself.

## White-label

The engine is invisible to customers, by construction rather than by policy:

- Its URL and admin token come from **environment variables** (`RUNDECK_URL`,
  `RUNDECK_API_TOKEN`), never a database row.
- This service exposes **no `/api/**` surface at all** and the gateway routes
  nothing to it. Its only caller is core-service over `X-Internal-Token`.
- The engine container publishes **no host port**.
- Nothing tenant-facing renders the word Rundeck. The console shows Jobs and
  Executions with AutoOps branding, and that is the whole story a customer gets.

The tenant-facing connection screens that existed in the first iteration were
**deleted, not hidden** — a hidden endpoint behind the gateway is still an
endpoint.

## Tenant isolation

One Rundeck now serves every customer, so the boundary moved from "a credential
per customer" to **a Rundeck project per AutoOps project**:

```
autoops-{sanitized tenantId}-{projectId}
```

`ProjectProvisioner` is that boundary and holds it three ways:

1. the name is **computed, never accepted** — no method takes a project name
   from a request;
2. the tenant id is **sanitized to `[a-z0-9-]` and length-bounded**, so a
   hostile workspace name cannot smuggle a path segment or an ACL glob into it;
3. `rundeck_projects` has a **unique key on the Rundeck name**, so even a
   careless change to the naming function cannot collapse two AutoOps projects
   onto one — it fails loudly instead.

Provisioning is lazy and idempotent: a 409 from Rundeck means the project
exists, which is the desired state, so it is success.

## How a step runs

```
core-service ExecutionEngine
   │  StepExecutor seam (unchanged)
   ▼
RundeckStepExecutor ──POST /internal/rundeck/step──► rundeck-service
                                                        │ 1. ensure the tenant's project
                                                        │ 2. translate the step -> bash
                                                        │ 3. POST /run/script (multipart)
                                                        │ 4. poll execution + log
                                                        ▼
                                                     the engine
```

**One step at a time, synchronously** — not a whole job imported into Rundeck.
Rundeck could orchestrate the workflow itself, and that would move orchestration
out of AutoOps, taking the approval gate, per-step retries, `continueOnError`
and cancel-between-steps with it. Those are the product. Rundeck is the hands;
AutoOps stays the brain, which is exactly what the `StepExecutor` seam already
assumed.

### Step type coverage

| AutoOps type | How it runs on the engine |
|---|---|
| `command`, `agent`, `script` | the body, as bash |
| `pyscript` | written to a temp file, run with the venv python (boto3, requests) |
| `ssh` | `ssh -o BatchMode=yes user@host <cmd>` |
| `rest` | `curl --fail-with-body`, method inferred from the body |
| `terraform` | HCL to a scratch dir, `init` + `plan\|apply\|destroy` (OpenTofu) |
| `kubernetes` | kubeconfig written 0600, `kubectl …`, manifest on stdin |
| `awslambda` | `aws lambda invoke`, response payload printed |
| `azurefn` | `curl`, function key in a header (never the URL) |
| `test` | `echo` |
| `powershell` | **refused** — see Known gaps |

The runtimes are pinned in `backend/rundeck-runtime/Dockerfile`, which fails the
build if any is missing.

### Two behaviours preserved from job-service, deliberately

- **No `set -euo pipefail` on a customer's body.** The obvious hardening is
  wrong here: the automation library pipes into `head` and `grep -q`, which
  close the pipe early and SIGPIPE the upstream command (exit 141). Under
  `pipefail` that is a failed step for a script that has worked for years. Only
  sequences *this service generates* turn on `set -e`.
- **An empty step body FAILS.** job-service's `ScriptRunner` refused one; without
  the guard the translator emits a script of nothing, exits 0, and the run log
  reads `ok` for a job that did nothing at all.

Both were found by running against real job definitions, not by review.

## Security

- **`X-Internal-Token` guards everything.** It now protects execution for every
  tenant on the platform, and the tenant is a *field* on the request rather than
  a token claim — so the check is constant-time and runs before any controller.
- **Credentials arrive decrypted, single-use, and are never persisted.** The
  dispatch receipt records the step type and execution id, never the body or the
  bundle.
- **Timeouts abort, never abandon.** A step past its budget has its engine
  execution aborted — the failure job-service's process-tree kill existed to
  prevent.
- **`ProdSafetyGuard` refuses to boot** with the default internal token, the
  default credential key, a missing engine token, or the dev engine token that
  ships in this repository.

### Credential injection — a named regression

Credentials are `export` lines at the top of the generated script. job-service
passed them as process environment and wrote them nowhere; Rundeck's ad-hoc
endpoint has no equivalent (secure options exist only for saved jobs, and Key
Storage would copy the vault into the engine).

Mitigated, not solved: tracing is disabled before the exports, values are
single-quote escaped, and the uploaded script is deleted after the run. **Do not
run the engine at `loglevel=DEBUG`.**

## Configuration

| Var | Default | Notes |
|---|---|---|
| `RUNDECK_URL` | `http://localhost:4440` | the engine, internal name only |
| **`RUNDECK_API_TOKEN`** | *(unset)* | admin on the engine. Nothing runs without it |
| **`RUNDECK_INTERNAL_TOKEN`** | `dev-internal-token` | guards execution for all tenants |
| `RUNDECK_STEP_TIMEOUT` | `10m` | ceiling on one step; hit = aborted upstream |
| `RUNDECK_POLL_INTERVAL` | `2s` | |
| `RUNDECK_PROJECT_PREFIX` | `autoops` | one ACL glob covers every AutoOps project |
| `RUNDECK_MAX_LOG_LINES` | `500` | per poll |

core-service side: `EXECUTION_MODE=rundeck` selects `RundeckStepExecutor`;
`EXECUTION_MODE=remote` rolls back to job-service — one variable and a restart.

## Run

```
mvn test             # 68 hermetic tests
docker compose up -d rundeck rundeck-service
```

## Known gaps

- **`notify` and `approval` step types are unimplemented — and always were.**
  14 real job definitions use them. They are *orchestration* steps and are
  handled nowhere in core-service, so they failed under job-service too (runs
  stopped earlier, on the empty-body guard, so it was never visible). They
  belong in `ExecutionEngine`, not in the engine. **This is the next decision to
  make, and it is a pre-existing gap rather than a regression.**
- **`powershell` is refused.** `pwsh` on Linux lacks the Windows-only cmdlets
  the 221-script library is written against, so installing it would mean failing
  deep inside someone's script rather than clearly at the boundary. The fix is a
  Windows execution node.
- **Cloud credential verification still lives in job-service.** Porting
  `/internal/verify` here is agreed and not yet done, so job-service cannot be
  deleted until it is.
- **`ssh` steps still have no key material**, exactly as under job-service.
- **The engine is single-instance.** It uses the stock H2 file database. A
  second replica needs a real datasource first.
- **Dispatch receipts carry no `runId` from core-service.** `StepExecutor` does
  not pass one, and widening that interface touches the engine and the simulated
  executor. Receipts are therefore per-step, not per-run.
