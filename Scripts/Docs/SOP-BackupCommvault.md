# SOP — Commvault Backup Automation

Standard operating procedure for the nine Commvault scripts in `Scripts/08-BackupCommvault`.

**Source:** `Agent_Automation_Feasibility_Assessment.xlsx`, sheet *Backup Commvault*, use cases #1–#9.

---

## 1. Prerequisites

| Requirement | Detail |
|---|---|
| PowerShell | 5.1 or later |
| Modules | **None.** Commvault ships no first-party PowerShell module; these scripts call the v11 REST API directly |
| Shared module | `Modules/IT-Automation-Common.psm1` — imported automatically |
| Config | `Config/config.json` → `commvault.webServiceUrl` |
| Network | HTTPS to the Web Server / web console API endpoint |

### Authentication

Two options. **Prefer the token.**

```powershell
# Preferred — no password is handled at any point
$token = Read-Host -AsSecureString 'Commvault Authtoken'
.\Get-CvBackupJobStatus.ps1 -AccessToken $token

# Alternative — prompts, or accepts a PSCredential
.\Get-CvBackupJobStatus.ps1 -Credential (Get-Credential)
```

Commvault's `/Login` requires the password **base64-encoded**, which means a credential login forces
the secret to exist as a plain managed string for as long as it takes to build one request body. The
scripts handle that as carefully as the API allows — the `BSTR` is zeroed in a `finally` block whether
or not the call succeeds, and the encoded copy is removed immediately afterwards — but `-AccessToken`
avoids the conversion entirely. That is why it is documented as preferred rather than as an
alternative.

**No password is ever read from `config.json`.** The config supplies the web service URL and nothing
else. If neither `-AccessToken` nor `-Credential` is supplied, the script prompts.

### Required CommCell permissions

| Script(s) | Permission |
|---|---|
| `Get-CvBackupJobStatus`, `Get-CvActiveJob`, `Get-CvScheduledJob`, `Get-CvBackupHealthReport` | View on the clients reported (plus View on libraries for the health report) |
| `Start-CvBackupJob`, `Restart-CvFailedJob` | Backup on the target subclients |
| `Export-CvTapeMedia` | Media Management on the library |
| `Set-CvSubclientConfiguration` | Agent Management on the target subclients |
| `Restore-CvBackupData` | Browse, plus In-Place and/or Out-of-Place Restore on the data and the destination client |

Use a dedicated CommCell account. Grant restore rights only to the account that needs them — the
restore script is the one that can overwrite live data.

---

## 2. Configuration

```powershell
Copy-Item .\Config\config.sample.json .\Config\config.json
notepad .\Config\config.json
```

Set `commvault.webServiceUrl`, e.g. `https://commserve.contoso.com/webconsole/api`. Everything else
in this category is a script parameter.

`config.json` must never be committed. There is currently **no `.gitignore` in this tree** — if you
place the library under version control, exclude it explicitly before the first commit.

---

## 3. Two endpoint paths you must verify first

Commvault's REST surface differs between versions in two places this library touches. Rather than
guess, both are exposed as parameters with **placeholder defaults**:

| Script | Parameter | Default | Action |
|---|---|---|---|
| `Export-CvTapeMedia` | `-ExportApiPath` | `Library/{0}/Media/{1}/action/export` | Check your CommCell REST reference |
| `Restore-CvBackupData` | `-RestoreApiPath` | `CreateTask` | Check your CommCell REST reference; the task body shape also varies |

Verify these against your own documentation before the first live run. A wrong path fails loudly
rather than doing something unintended, but it will fail.

---

## 4. Reporting

The four read-only scripts are safe to schedule unattended.

```powershell
.\Get-CvBackupJobStatus.ps1   -LookbackHours 24 -OutputFormat HTML -OutputPath .\reports\jobs.html
.\Get-CvActiveJob.ps1         -LongRunningHours 6
.\Get-CvScheduledJob.ps1      -LookaheadDays 2
.\Get-CvBackupHealthReport.ps1 -LookbackHours 24 -ExpectedIntervalHours 36
```

### Reading these honestly

- **The health report's most important finding is an absence.** A client that has silently stopped
  backing up does not appear in a job report at all — there are no failed jobs to see. It appears as
  a `StaleClient` row. Keep `-ExpectedIntervalHours` set to your actual backup interval; a client
  backed up weekly will look stale against a 36-hour default and that is a false alarm, not a finding.
- **Library capacity is reported as raw values plus a percentage**, not relabelled as GB. The unit
  Commvault uses for those fields varies; the percentage is unit-independent and is what the
  threshold tests. If the endpoint returns nothing, the capacity section is **omitted rather than
  estimated**, and the omission is logged.
- **Scheduled jobs may have no next-run time.** Whether Commvault returns a resolved next-run epoch
  depends on the version and the pattern type. Where it does not, the schedule is listed with
  `NextRun = null`, its pattern, and `NextRunSource` saying so — the script does **not** re-implement
  Commvault's scheduler to fill the gap. A computed time that disagreed with the CommCell would be
  worse than no time. Those rows are not filtered by the lookahead horizon, and the count is logged.
- **Active-job filtering is applied twice** — server-side via the query parameter and again in the
  script. A CommCell version that ignores the parameter still produces a correct list.

---

## 5. Running backups

```powershell
.\Start-CvBackupJob.ps1 -ClientName SQLPROD01 -BackupLevel Full
.\Start-CvBackupJob.ps1 -ClientName FILESRV01 -SubclientName default -BackupLevel Incremental -WhatIf
```

`-BackupLevel` defaults to `Incremental`, not `Full`. A Full where the schedule expects an Incremental
changes storage consumed and the synthetic-full chain, so the level is a deliberate choice. A
subclient with a job already running is skipped unless `-AllowConcurrent` is passed — a second
concurrent job normally queues behind the first and confuses the schedule. Every submitted job id is
logged so it can be tracked or killed.

### Re-running failures — the window is enforced, not suggested

```powershell
.\Restart-CvFailedJob.ps1 -LookbackHours 12
.\Restart-CvFailedJob.ps1 -LookbackHours 24 -IgnoreWindow -WhatIf   # ticketed catch-up
```

Outside the backup window this script **throws**. It does not queue the work for later. `-IgnoreWindow`
overrides that for a ticket-driven catch-up and logs a WARN recording that it did.

Failures whose reason matches `-ExcludeReasonPattern` are not retried — expired licence, bad
credential, access denied, missing path. Retrying those burns a backup window and fails identically.
The default patterns cover the common cases; extend them for your environment. `-MaxJobs` caps a run
at 25, and if it drops jobs it says how many.

---

## 6. Tape export — the script does half the job

```powershell
.\Export-CvTapeMedia.ps1 -LibraryName TAPELIB01                      # report + approval
.\Export-CvTapeMedia.ps1 -LibraryName TAPELIB01 -MediaBarcode ABC123L8 `
    -ApprovalReference APR-... -TicketReference INC0012345
```

The API call moves the cartridge to the mail slot. **It does not remove it from the building.** The
run produces a pick list naming every barcode and slot, and is not complete until a person has
collected and vaulted them. Both the result rows and the success log say so explicitly.

Mounted or in-use media are excluded automatically — ejecting a cartridge mid-write is the failure
this prevents.

---

## 7. Configuration drift — reporting is automatic, design is not

```powershell
.\Set-CvSubclientConfiguration.ps1 -DesiredStateFile .\baseline.json          # report + approval
.\Set-CvSubclientConfiguration.ps1 -DesiredStateFile .\baseline.json `
    -ApplyProperty description,enableBackup -ApprovalReference APR-...
```

Two independent brakes:

1. **Nothing is written unless named in `-ApplyProperty`.** Omit it and the script reports drift and
   changes nothing.
2. **Design properties are refused outright.** Storage policy, retention, backup level, schedule
   policy and content paths encode *what is protected, how often, and for how long* — the decisions
   the workbook reserves for a human. They are reported as drift but are not actionable without
   `-DesignApproved`, which additionally requires a `-Reason` naming the design authority who made
   the call.

There is no built-in baseline, deliberately. A shipped default for what a subclient *should* look
like would be exactly the protection-design decision this gate exists to protect.

---

## 8. Restore — read this before you run it

This is the only Destructive row in the category and the only script here that can destroy data.

```powershell
# Out-of-place. Both destination parameters are required; neither is defaulted.
.\Restore-CvBackupData.ps1 -ClientName FILESRV01 -SourcePath 'D:\Shares\Finance' `
    -DestinationClient FILESRV02 -DestinationPath 'D:\Restore' -FromJobId 123456

# In-place. Overwrites live data. Requires a second explicit flag.
.\Restore-CvBackupData.ps1 -ClientName FILESRV01 -SourcePath 'D:\Shares\Finance' `
    -InPlace -OverwriteConfirmed -PointInTime '2026-08-01 02:00' `
    -ApprovalReference APR-... -TicketReference INC0012345 -Execute
```

**Nothing is defaulted, and that is the design:**

- Out-of-place requires **both** `-DestinationClient` and `-DestinationPath`.
- `-InPlace` is mutually exclusive with those and **additionally** requires `-OverwriteConfirmed`.
- The version must be `-FromJobId` **or** `-PointInTime`. There is no "latest".

A restore that silently picked "latest, in place" is the accident this gate exists to prevent.

On top of that: report-only by default, plus `-Execute`, plus a valid `-ApprovalReference`.

**Rollback:** none for an in-place restore. It overwrites whatever is at the destination and no script
can undo it. An out-of-place restore writes to a new location and can simply be deleted — which is why
the two are gated differently.

**Validating that the restored data is actually correct is a human step.** The script submits the job
and reports the job id. It does not check the result, and the success log says the validation is
still outstanding. Do not close the ticket on the strength of a submitted job.

---

## 9. Audit trail

Every script logs through `Write-AutomationLog` — timestamp, level, the target touched, the acting
script. Credential-shaped strings are redacted from every log line and every approval artifact before
they are written, which the module test suite proves.

Approval artifacts live in `%ProgramData%\ITAutomation\Approvals`. A reference is single-script and
expires; it cannot be replayed against a different action.

The REST session is closed on **every** exit path — including the no-candidates, request-approval and
report-only early returns, not just the success path.

---

## 10. Known limitations

- **No script in this category has been executed against a real CommCell.** Validation is static
  analysis (`Invoke-ScriptAnalyzer`, 0 findings), AST parse, and module-level unit tests with mocked
  inputs. Run each one against a test CommCell first.
- **Two endpoint paths are placeholders** (section 3). Verify them.
- **The restore task body shape varies by Commvault version.** The one built here follows the v11
  `CreateTask` structure; confirm it against your own REST reference before relying on it.
- The health report derives "no successful backup" from job history inside the lookback window. It
  does not read a CommCell SLA definition, so it reports against **your** `-ExpectedIntervalHours`
  rather than against whatever SLA is configured in the product.
