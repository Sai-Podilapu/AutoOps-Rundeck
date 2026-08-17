# SOP — Microsoft 365 Automation

Standard operating procedure for the twenty-two M365 scripts in `Scripts/05-M365`.

**Source:** `Agent_Automation_Feasibility_Assessment.xlsx`, sheet *M365*, use cases #1–#22.

---

## 1. Prerequisites

| Requirement | Detail |
|---|---|
| PowerShell | 5.1 or later |
| Modules | `Microsoft.Graph` (Authentication, Teams, Sites, Files, DeviceManagement, Identity.SignIns, Identity.Governance, Users, Groups, Planner, Reports, Security), `ExchangeOnlineManagement` |
| Shared module | `Modules/IT-Automation-Common.psm1` — imported automatically by each script |
| Config | `Config/config.json` — copy from `config.sample.json` and populate |
| Licensing | Entra ID **P2** for #11 and #18; Defender for Office 365 for #19; Intune for #6–#8 |

Each script declares its own `#Requires` modules and calls `Test-Prerequisite`, which **fails closed**
— a missing module stops the run with the name of the failing check, rather than proceeding on a
partial surface.

### Authentication

Two endpoints are in play and a working connection to one does **not** imply the other.

| Endpoint | Used by | Auth |
|---|---|---|
| Microsoft Graph | #1–#14, #18, #21, #22 | `Connect-MgGraph` with least-privilege scopes, declared per script |
| Exchange Online | #15, #16, #17, #19 | `Connect-ExchangeOnline`, app-only **certificate** auth |
| Security & Compliance | #20 | `Connect-IPPSSession` — a separate session from Exchange Online |

App-only certificate authentication is required for the Exchange endpoints. The scripts read the
application id, certificate thumbprint and tenant from `Config/config.json` and **throw if they are
absent** rather than falling back to interactive auth in an unattended context. No client secret is
read from config, and no credential of any kind is stored in a script.

### Required permissions

| Script(s) | Permission |
|---|---|
| `New-TeamsChannel`, `Remove-TeamsInactiveChannel` | Graph `Channel.ReadWrite.All`, `Group.Read.All` |
| `New-SharePointSite`, `Get-SharePointStorageReport` | Graph `Sites.ReadWrite.All` / `Sites.Read.All` |
| `Get-OneDriveExternalSharing` | Graph `Files.Read.All`, `Sites.Read.All` |
| `Get-IntuneDeviceCompliance`, `Add-IntuneAppAssignment`, `Clear-IntuneManagedDevice` | Graph `DeviceManagementManagedDevices.*`, `DeviceManagementApps.ReadWrite.All` |
| `Get-M365LicenseOptimization` | Graph `Organization.Read.All`, `User.Read.All` |
| `Get-EntraConditionalAccessAudit` | Graph `Policy.Read.All` |
| `Get-EntraPimActivationReport` | Graph `RoleManagement.Read.Directory` (**Entra ID P2**) |
| `Get-M365SecureScore` | Graph `SecurityEvents.Read.All` |
| `Remove-TeamsMeetingRecording` | Graph `Files.ReadWrite.All`, `User.Read.All` |
| `New-PlannerTask` | Graph `Tasks.ReadWrite`, `Group.Read.All` |
| `Export-M365AuditLog` | EXO **View-Only Audit Logs**; unified audit logging enabled on the tenant |
| `Set-ExoAntiSpamPolicyBaseline` | EXO **Hygiene Management** to apply; View-Only Configuration to report |
| `Get-M365DlpMatchReport` | EXO View-Only Recipients + Security Reader |
| `Get-EntraRiskySignInReport` | Graph `IdentityRiskEvent.Read.All`, `AuditLog.Read.All` (**P2**) |
| `Get-M365EmailThreatReport` | EXO Security Reader + View-Only Audit Logs |
| `Get-M365RetentionCompliance` | Compliance **View-Only Retention Management** |
| `Get-VivaInsightsUsageReport` | Graph `Reports.Read.All` |
| `Get-PowerPlatformConnectorAudit` | **Power Platform administrator** (separate from Graph) |

Grant these to a dedicated app registration. Do not reuse a personal admin identity — the audit trail
records the acting identity and a shared one makes it worthless.

---

## 2. Configuration

```powershell
Copy-Item .\Config\config.sample.json .\Config\config.json
notepad .\Config\config.json
```

Populate before first use:

- `azure.tenantId`, `azure.applicationId`, `azure.certificateThumbprint` — the app registration.
- `notifications` — SMTP relay and recipients, if reports are to be mailed.

`config.json` holds tenant-identifying values and **must never be committed**. `config.sample.json`
is the only one intended for the repository and it contains no real values. Note there is currently
**no `.gitignore` in this tree** — if you place this library under version control, exclude
`Config/config.json` explicitly before the first commit.

---

## 3. Running the reports

All twelve read-only scripts are safe to schedule unattended. They issue no write call.

```powershell
.\Get-IntuneDeviceCompliance.ps1     -OutputFormat HTML -OutputPath .\reports\intune.html
.\Get-M365SecureScore.ps1            -IncludeControls -DropAlertPoints 5
.\Get-EntraRiskySignInReport.ps1     -LookbackDays 1 -MinimumRiskLevel medium
.\Export-M365AuditLog.ps1            -LookbackHours 24 -OutputFormat JSON -OutputPath .\siem\m365.json
```

Suggested cadence:

| Cadence | Scripts |
|---|---|
| Daily | #18 risky sign-ins, #15 audit export (SIEM feed) |
| Weekly | #6 Intune compliance, #17 DLP, #19 Defender threats, #12 Secure Score |
| Monthly | #4 SharePoint storage, #5 OneDrive sharing, #9 licence optimisation, #10 CA audit, #11 PIM, #20 retention, #21 usage, #22 connectors |

### Reading these reports honestly

Four of them will mislead you if read naively, and each says so in `.NOTES`:

1. **#15 audit export** — unified audit ingestion lags **up to 24 hours** for some workloads. A run
   covering the last hour is incomplete by design. Overlap the windows and de-duplicate downstream on
   `Id`. If the run hits `-MaxRecords` it logs a WARN saying the export is truncated; do not treat a
   capped export as a full one.
2. **#18 risky sign-ins / #11 PIM** — without Entra ID P2 these endpoints return nothing. The script
   reports *missing licensing*, not a clean result. An empty report from an unlicensed tenant means
   "not measured", not "no risk".
3. **#21 usage** — if "Display concealed user information" is enabled in the M365 admin centre, user
   names are replaced with opaque identifiers. The script detects and reports this. It is a privacy
   setting working correctly, not a fault.
4. **#12 Secure Score** — the first run has no previous state and reports `first run`. It does not
   invent a baseline to compare against.

---

## 4. The gated scripts

Five rows carry a guardrail in column L. Each is enforced in code; none can be bypassed with a flag.

### #7 Intune app deployment — approval gate

```powershell
# 1. Produce the change set and raise an approval
.\Add-IntuneAppAssignment.ps1 -AppName '7-Zip' -GroupName 'All-Workstations' -Intent Required
# -> APR-20260809-xxxx

# 2. A human reviews and approves the artifact under %ProgramData%\ITAutomation\Approvals

# 3. Apply
.\Add-IntuneAppAssignment.ps1 -AppName '7-Zip' -GroupName 'All-Workstations' -Intent Required `
    -ApprovalReference APR-20260809-xxxx -TicketReference INC0012345
```

The change set names **both** things the guardrail asks to approve — the app and the resolved target
group — and records the group's member count, so the approver sees the blast radius rather than a
group name. `Required` installs silently at next check-in; `Available` only offers the app in Company
Portal. Re-running against an existing assignment with the same intent is a logged no-op.

### #2 Teams inactive channel cleanup — archive first

`-Mode Archive` is the default, which is what the guardrail asks for. `-Mode Delete` additionally
requires `-OwnerConfirmed`; without it the script throws. Activity is measured from the last message
in the channel, and a channel whose history cannot be read is **skipped rather than assumed
inactive**. `General` is excluded unconditionally — Teams does not permit its deletion.

```powershell
.\Remove-TeamsInactiveChannel.ps1 -MinimumAgeDays 90                 # report + approval
.\Remove-TeamsInactiveChannel.ps1 -MinimumAgeDays 90 -Mode Delete `
    -OwnerConfirmed -ApprovalReference APR-... -Execute
```

### #13 Teams recording cleanup — confirm holds first

**Before running this at all**, confirm in the Purview portal that no eDiscovery or litigation hold
covers the mailboxes in scope. The Graph API this script uses can see **item-level retention labels
only** — it cannot see tenant-level holds. Items carrying a retention label are excluded
automatically; everything else depends on your check.

`-LegalHoldConfirmed` is mandatory and is you asserting that check was done. Deleted items go to the
OneDrive recycle bin and are recoverable for 93 days, then permanently removed.

### #8 Intune retire/wipe — the most destructive row in this category

Report-only by default, plus `-Execute`, plus a valid `-ApprovalReference`. `Retire` is the default
and removes company data only. `-Action Wipe` resets the device to factory state, destroys personal
data on a BYOD device, and additionally requires `-ItsmTriggerVerified` — the verified ITSM trigger
the guardrail names.

**Rollback: none.** A wiped device is re-enrolled, not restored. Confirm the device serial and the
user before approving, not after.

### #16 Anti-spam policy — the judgement is yours

This one is assist-only *and* approval-gated. It compares each policy against a baseline and reports
every deviation with the trade-off stated on the row. It changes nothing until a reference is
approved.

```powershell
# 1. Review
.\Set-ExoAntiSpamPolicyBaseline.ps1 -OutputFormat HTML

# 2. Apply only the part you agreed to
.\Set-ExoAntiSpamPolicyBaseline.ps1 -ApprovalReference APR-... `
    -ApplySetting PhishSpamAction,HighConfidencePhishAction
```

The built-in baseline is a **starting point for a conversation, not a target**. Tightening spam
policy affects legitimate mail as well as spam: quarantining instead of moving to junk means users
stop seeing false positives at all, which is safer *and* generates more helpdesk contact. That
trade-off is the messaging admin's call, which is why `-ApplySetting` exists — approve the review,
then apply part of it. Each change logs the previous value; that log is the rollback.

---

## 5. Audit trail

Every script writes to `Logs/` through `Write-AutomationLog`, recording timestamp, level, the
**target** that was touched, and the acting script. Credential-shaped strings are redacted from every
log line and every approval artifact before they are written — proven by the module test suite, not
by inspection.

For the gated scripts the trail is: candidate list → approval artifact (Pending) → human approval →
execution logged per object. An approval reference is single-script and expires; it cannot be
replayed against a different action.

---

## 6. Known limitations

Stated so nobody discovers them during an incident:

- **No script in this category has been executed against a real tenant.** Validation to date is
  static analysis (`Invoke-ScriptAnalyzer`, 0 findings), AST parse, and module-level unit tests with
  mocked inputs. Run each one in a test tenant first.
- **#22 Power Platform** uses the Power Platform admin REST API, which is not Graph and needs the
  Power Platform administrator role. If that role is already delegated elsewhere, the
  `Microsoft.PowerApps.Administration.PowerShell` module may be the simpler route.
- **#17 DLP** aggregates by policy and rule. Per-incident detail is deliberately not exported —
  incident bodies routinely contain the sensitive data that triggered the match. Use the Purview
  portal for that.
- **#19 Defender** detail reports cover 30 days at most and the current day is always partial.
