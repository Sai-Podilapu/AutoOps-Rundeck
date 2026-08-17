# Master Prompt — PowerShell Script Generation from Automation Assessment Workbook

> **How to use:** Put `Agent_Automation_Feasibility_Assessment.xlsx` in your working folder, open Claude Code there, and paste **Section 1** as your first message. Then use the batch prompts in Section 2 to work through the sheets. Section 3 has follow-up prompts for review, testing, and packaging.

---

## SECTION 1 — THE MASTER PROMPT (paste this first)

```
You are a senior infrastructure automation engineer specializing in PowerShell.
I have uploaded `Agent_Automation_Feasibility_Assessment.xlsx` to this folder. It
contains 213 IT automation use cases across 13 platform categories. Your job is to
generate production-grade PowerShell scripts for these use cases.

## STEP 1 — READ AND UNDERSTAND THE WORKBOOK

Read the workbook with Python (openpyxl or pandas — do NOT guess at contents).
Structure:
- Sheet `Summary` — rollup dashboard. Read it for context, generate nothing from it.
- 13 category sheets: AWS, Azure, Azure AVD, OCI, M365, Security Cloud,
  Network Devices, Backup Commvault, Hyper-V, VMware OnPrem, Windows Server,
  Exchange & O365, AD & Identity.

On every category sheet: row 1 = title banner, row 3 = headers, data starts row 4.
Columns A–L:
  A  #
  B  Automation Task
  C  Technology / Tool
  D  Platform
  E  Current Status
  F  Agent Automation Possible?          (Yes | Partial)
  G  Difficulty Level                    (Low | Medium | High)
  H  Agent Can Execute with Clear SOP?   (Yes | Yes - With Approval | Partially - Agent Assists)
  I  Automation Type                     (Read / Report | Change / Write | Destructive / High-Impact)
  J  Risk Level                          (Low | Medium | High)
  K  Human Approval Needed?              (Yes | No)
  L  Remarks / Guardrails

Columns I, J, K and L are the specification for HOW each script must behave. Do not
ignore them — they determine safety controls, not just documentation.

## STEP 2 — OUTPUT STRUCTURE

Create this layout in the working directory:

  /Scripts
    /01-AWS
    /02-Azure
    /03-AzureAVD
    /04-OCI
    /05-M365
    /06-SecurityCloud
    /07-NetworkDevices
    /08-BackupCommvault
    /09-HyperV
    /10-VMwareOnPrem
    /11-WindowsServer
    /12-ExchangeO365
    /13-ADIdentity
  /Modules
    IT-Automation-Common.psm1     # shared logging, auth, notification, approval helpers
  /Config
    config.sample.json            # sample config; NEVER a real one with secrets
  /Docs
    SOP-<Category>.md             # one SOP doc per category
  MANIFEST.md                     # generated index: use case # -> script file -> status

File naming: `Verb-Noun.ps1` using approved PowerShell verbs.
  e.g. "AWS S3 Bucket Public Access Audit" -> `Get-AwsS3PublicAccessAudit.ps1`
       "Azure Disk Unattached Cleanup"     -> `Remove-AzUnattachedDisk.ps1`
       "Hyper-V VM Snapshot Creation"      -> `New-HvVmCheckpoint.ps1`

## STEP 3 — MANDATORY SCRIPT STANDARDS

Every script must have ALL of the following. A script missing any of these is not done.

1. **Comment-based help** — .SYNOPSIS, .DESCRIPTION, .PARAMETER (each one),
   .EXAMPLE (at least 2), .NOTES containing: source use case number, category,
   difficulty, risk level, required permissions, required modules, and the
   verbatim Remarks/Guardrails text from column L.

2. **`[CmdletBinding()]` with a proper `param()` block.** No hardcoded values —
   server names, subscription IDs, thresholds, paths, and recipients are all
   parameters with sensible defaults where safe.

3. **`#Requires`** statements for PowerShell version and each required module.

4. **Structured logging** — every script writes a timestamped log via the shared
   `Write-AutomationLog` helper (levels: INFO / WARN / ERROR / SUCCESS). Log the
   start, every target acted upon, every decision made, and the outcome.

5. **Error handling** — `$ErrorActionPreference = 'Stop'` at the top, try/catch
   around every external call, meaningful error messages, and a non-zero exit code
   on failure. Never let a script fail silently or half-complete a batch without
   reporting which items succeeded.

6. **Structured output** — return `[PSCustomObject]` collections, not formatted
   strings. Support `-OutputFormat Console|CSV|JSON|HTML` where a report is produced.

7. **Idempotency** — re-running must not double-apply. Check current state first.

8. **No credentials in code, ever.** Use managed identity / service principal /
   secret vault / `Get-Credential` / `-Credential` parameter. Never a plaintext
   password, key, or token — not even as a placeholder default value.

## STEP 4 — SAFETY CONTROLS DRIVEN BY THE WORKBOOK COLUMNS

Apply these based on the row's values. This is the most important part of the task.

**Column I = "Read / Report"**
  - Read-only. The script must contain NO write/modify/delete calls at all.
  - Safe to schedule unattended.

**Column I = "Change / Write"**
  - Add `[CmdletBinding(SupportsShouldProcess)]` and wrap every change in
    `if ($PSCmdlet.ShouldProcess($target, $action))`.
  - Add a `-WhatIf`-clean dry run path and log the intended change before making it.
  - Where a rollback is feasible, capture prior state to a rollback file first.

**Column I = "Destructive / High-Impact"**
  - `SupportsShouldProcess` with `ConfirmImpact = 'High'` (prompts by default).
  - **Two-phase by design:** the script must default to REPORT-ONLY, producing the
    candidate list. Actual deletion/wipe/failover happens only when an explicit
    `-Execute` (or `-Force`) switch is passed.
  - Mandatory pre-action backup/snapshot/export where the platform allows it.
  - Hard safety filters (age thresholds, name patterns, tag exclusions, environment
    exclusions) as parameters with conservative defaults.
  - A `-ProtectedList` / exclusion-file parameter that can never be overridden.
  - Log every single object acted upon, individually, before acting.

**Column K = "Yes" (Human Approval Needed)**
  - The script must NOT act on its own. Implement an approval gate:
    generate the change set -> raise/attach to an ITSM ticket or send for approval
    -> accept an `-ApprovalReference` (ticket ID / approval token) parameter ->
    refuse to execute without it and log the reference in the audit trail.
  - Include a `-RequestApproval` mode that only produces the change set + summary.

**Column H = "Partially - Agent Assists"**
  - Automate ONLY the mechanical part described in column L. Do not attempt to
    script the human judgment step.
  - The script's job is to gather, enrich, compare against a baseline, and produce a
    decision-ready package for a human — then stop.
  - Clearly state in .DESCRIPTION which part is automated and which part is human.

**Column J = "High" (Risk Level)**
  - Add a pre-flight validation function that verifies connectivity, permissions,
    target existence, and safety preconditions BEFORE any action.
  - Add post-action verification that confirms the intended end state.
  - Require `-Confirm` unless explicitly suppressed.

## STEP 5 — PLATFORM MODULES AND AUTH

Use these, and state the auth method in .NOTES:
  AWS               -> AWS.Tools.* modules (Set-AWSCredential / IAM role / SSO)
  Azure / AVD       -> Az.* modules (Connect-AzAccount, managed identity preferred)
  Entra ID / M365   -> Microsoft.Graph SDK (app registration + certificate auth)
  Exchange Online   -> ExchangeOnlineManagement (Connect-ExchangeOnline, cert auth)
  SharePoint/OneDrive -> PnP.PowerShell
  Active Directory  -> ActiveDirectory module (delegated service account)
  VMware            -> VMware.PowerCLI (Connect-VIServer, credential store)
  Hyper-V           -> Hyper-V module + SCVMM cmdlets where noted
  Windows Server    -> native cmdlets over PSRemoting/WinRM
  Commvault         -> Invoke-RestMethod against Commvault REST API (token auth)
  OCI               -> wrap the OCI CLI or call OCI REST from PowerShell
                       (no first-party PS module — note this limitation in .NOTES)
  Network Devices   -> Posh-SSH module. IMPORTANT: flag in .NOTES that Python/Netmiko
                       is the better fit for multi-vendor CLI parsing, and keep the
                       PowerShell version simple (command execution + raw capture).
  Security tooling  -> REST APIs via Invoke-RestMethod

## STEP 6 — SHARED MODULE

Build `/Modules/IT-Automation-Common.psm1` FIRST, before any scripts, exporting:
  Write-AutomationLog        (structured, file + console, log rotation)
  Connect-AutomationPlatform (per-platform auth wrapper)
  Send-AutomationReport      (email / Teams webhook / ITSM)
  New-ApprovalRequest        (creates the approval artifact, returns a reference)
  Test-ApprovalReference     (validates an approval token before execution)
  Export-AutomationResult    (CSV / JSON / HTML output)
  Test-Prerequisite          (module + permission + connectivity pre-flight)
  Get-AutomationConfig       (reads /Config/config.json)
Every generated script imports this module rather than duplicating helpers.

## STEP 7 — WORKING METHOD

- Do NOT try to generate all 213 scripts at once. Work in batches by category.
- Start by reading the workbook and printing a plan: category, count of use cases,
  and the breakdown by Automation Type / Risk / Approval. Then STOP and wait for me
  to tell you which category to build.
- After each batch: update MANIFEST.md, run `Invoke-ScriptAnalyzer` on every new
  script, fix all Error and Warning findings, and give me a short summary of what
  was created and anything you flagged as needing my input.
- If a use case in the workbook is ambiguous or you'd need environment-specific
  detail I haven't given you (naming conventions, OU paths, subscription IDs, SMTP
  relay, ITSM endpoint), do NOT invent it. Add it as a parameter with a clearly
  marked placeholder default and list it in MANIFEST.md under "Needs Input".

## STEP 8 — WHAT NOT TO DO

- Do not produce stub scripts with `# TODO: implement logic`. Every script must be
  functionally complete against real cmdlets/APIs.
- Do not write credentials, tenant IDs, subscription IDs, or hostnames into code.
- Do not make a Destructive script delete by default.
- Do not skip the approval gate on any row where column K is "Yes".
- Do not merge multiple use cases into one script unless I ask.

START NOW with Step 1 and Step 7's planning output. Read the workbook, show me the
plan, then wait for my instruction on which category to build first.
```

---

## SECTION 2 — BATCH PROMPTS (use after the plan)

Run these one at a time. Suggested order builds confidence before touching risky things.

**Batch 1 — foundation**
```
Build /Modules/IT-Automation-Common.psm1 and /Config/config.sample.json now, in
full. Include Pester tests for the module in /Tests. Then show me the exported
function signatures so I can confirm before you use them everywhere.
```

**Batch 2 — safest category first**
```
Generate all scripts for the "Windows Server" sheet. Follow the master standards
exactly. Then run Invoke-ScriptAnalyzer, fix findings, and update MANIFEST.md.
```

**Batch 3 onward — repeat per category**
```
Generate all scripts for the "<CATEGORY NAME>" sheet. Same standards. Pay special
attention to the rows where column I is "Destructive / High-Impact" or column K is
"Yes" — show me those scripts' safety controls in your summary so I can verify the
gates are real.
```

Suggested order: Windows Server → Hyper-V → VMware OnPrem → AWS → Azure → Azure AVD → M365 → Exchange & O365 → AD & Identity → Backup Commvault → OCI → Network Devices → Security Cloud.

*(Security Cloud last — it has the most "Partial" rows and needs the most judgment about what to automate.)*

---

## SECTION 3 — FOLLOW-UP PROMPTS

**Safety audit**
```
Audit every script you've generated against the workbook. For each one, verify:
(a) Destructive rows default to report-only and require -Execute
(b) Approval-required rows refuse to run without -ApprovalReference
(c) Read/Report rows contain zero write operations
(d) No credentials or environment-specific IDs are hardcoded
Produce a table of any script that fails a check, and fix them.
```

**SOP generation**
```
For each category, write /Docs/SOP-<Category>.md covering: prerequisites, required
permissions, how to configure, how to run each script, expected output, the approval
workflow where applicable, rollback procedure, and troubleshooting. Base the guardrail
sections on column L of the workbook.
```

**Testing scaffold**
```
Create Pester tests in /Tests for every script: parameter validation, -WhatIf
behavior, error handling paths, and (for destructive scripts) a test proving the
script does nothing without -Execute. Mock all external platform calls.
```

**Packaging**
```
Package everything: a root README.md with setup instructions, a bootstrap script
that installs required modules, and a scheduling reference (Task Scheduler / Azure
Automation runbook / AWS Systems Manager) for the scripts safe to run unattended —
i.e. only the Read/Report rows with Risk = Low.
```

---

## TIPS

- Claude Code will read the .xlsx with Python — you don't need to convert it to CSV first.
- Keep batches to one category so scripts stay high quality and context stays clean.
- Review the Destructive and Approval-gated scripts yourself before anything touches production. The prompt builds the gates, but only you know your change-control rules.
- If your org has naming conventions, OU structures, or an ITSM endpoint, paste them into Claude Code once at the start — it'll bake them in instead of leaving placeholders.
