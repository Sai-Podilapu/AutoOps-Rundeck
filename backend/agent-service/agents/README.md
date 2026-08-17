# Provider-authored agent definitions

One file per agent, grouped by technology domain. These are the **source of
truth** for the provider catalog: a file here is authored once, published to
`library_items` as a `type='AGENT'` row, and rolled out to every customer from
there. Customers receive sealed copies — they may run, enable and disable an
agent and can see its tool allow-list, but never read its `instructions`.

```
agents/
  _schema/agent.schema.json     validation contract for every file below
  AWS/                          RD-126 … RD-151
  Linux/                        RD-079 … RD-100
  Azure/  ActiveDirectory/  WindowsServer/  SQLServer/  VMware/
  Network/  Security/  Microsoft365/  ExchangeOnPrem/
```

File name is `<RD-ID>-<kebab-name>.json`, matching the task id in the project
tracker so an agent is traceable to the use case that justified it.

## How a file maps to the platform

`RolloutService.rollOutAgent` reads a catalog agent's `definition` column as
`{"description", "model", "instructions", "tools"}`. Everything else in these
files is authoring metadata — it drives the catalog listing, the tracker
crosswalk and the input form, and is stripped before the definition is stored.

## Tool references are by `ref`, not by id

```json
"tools": [ { "type": "WORKFLOW", "ref": "RD-079-linux-server-health-check" } ]
```

A numeric id is meaningless across tenants: workflow #42 in the provider's
workspace is a different automation in the customer's. `AgentService.
normalizeTools` rejects an unresolvable id outright (`unknown_tool_target`),
so an agent authored with raw ids fails to roll out to every customer.
Referencing the stable `ref` lets rollout resolve each one to the tenant's own
delivered copy via `source_id`.

**This resolution step does not exist yet.** Until it is built, agents with a
non-empty allow-list cannot be delivered. Authoring against `ref` now means
none of these files need rewriting once it lands.

## Inputs live on the WORKFLOW, not here

`inputs[]` is declared once, in `workflows/<DOMAIN>/<RD-ID>.json`. Agents
deliberately do not restate it. Two copies drift — the first version of this
tree had them in both places and they were already inconsistent within a day —
and a form that disagrees with the model's tool schema is worse than either
alone.

Each field carries `consumedBy`: `node` (default) means a `{{placeholder}}` in
a step must use it, and the validator fails if none does. `agent` means the
value reaches the model as a tool argument and informs its judgement instead —
a threshold to compare against rather than a shell flag.

That one declaration drives both sides, so they cannot drift:

- **Human path** — the console renders the form, validates against `pattern`,
  `min`/`max`, `options` and `required`, and refuses to dispatch until valid.
- **Model path** — `AgentToolbox.schemaFor` turns the same fields into the
  tool's JSON schema, where `options` becomes `enum` and `required` becomes the
  schema's required list.

**Known gap.** `InternalAgentDispatchController.workflowInputs` currently
returns an empty field list for any workflow that is not Dify-backed, so a
native workflow exposes no form at all today. These `inputs[]` blocks are
written to the shape that endpoint already returns (`variable`, `label`,
`type`, `required`, `options`) so wiring it to read them is a change to one
method, not a redesign.

## Field reference

| Key | Meaning |
|---|---|
| `variable` | Name passed to the automation. Must match the workflow input. |
| `label` | What the operator sees. |
| `type` | `string`, `number`, `boolean`, `select`. |
| `required` | Blocks dispatch when empty. |
| `options` | `select` only. Becomes `enum` in the model's tool schema. |
| `pattern` | ECMA regex the value must match. |
| `min` / `max` | `number` only, inclusive. |
| `default` | Pre-filled; still validated. |
| `help` | Shown under the field. State the blast radius here. |
| `requiredWhen` | `{"field":"x","equals":true}` — conditionally mandatory. |

## Authoring rules

1. **Never invent a parameter.** Every `variable` must correspond to a real
   parameter of the underlying script or workflow. Where a script asset exists
   its `param()` block is the contract; `sourceScript` records which file.
2. **Default to read-only.** An agent that changes state declares
   `approvalRequired: true` and carries an approval input.
3. **State the blast radius in `help`**, not just the type. "Deletes matching
   buckets' public ACLs" beats "remediation flag".
4. **`instructions` is the product.** It is the one field customers never see,
   and the reason a rolled-out agent is worth paying for.
5. `runtime` records what the automation needs to execute. `powershell` is
   currently **blocked** — job-service has no PowerShell runner and no WinRM
   transport, so those agents are authored but not yet runnable.
