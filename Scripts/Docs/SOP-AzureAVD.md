# SOP — Azure Virtual Desktop Automation

Standard operating procedure for the eight scripts in `Scripts/03-AzureAVD`.

**Source:** `Agent_Automation_Feasibility_Assessment.xlsx`, sheet *Azure AVD*, use cases #1–#8.

---

## 1. Prerequisites

| Requirement | Detail |
|---|---|
| PowerShell | 5.1 or later |
| Modules | `Az.Accounts`, `Az.DesktopVirtualization`; plus `Az.Compute` (#2, #4, #7), `Az.Resources` (#6), `Az.OperationalInsights` (#8) |
| Shared module | `Modules/IT-Automation-Common.psm1` — imported automatically |
| Authentication | The ambient Azure context. Managed identity preferred; otherwise `Connect-AzAccount` first |

No AVD credential is stored anywhere. `#5` reads an SMB share and uses the caller's Windows identity.

### Required roles

| Script(s) | Role |
|---|---|
| `Set-AvdSessionHostDrainMode`, `Update-AvdHostPoolImage` | Desktop Virtualization Host Pool Contributor |
| `Disconnect-AvdUserSession` | Desktop Virtualization Session Host Contributor |
| `Set-AvdHostPoolScale`, `Restore-AvdSessionHost` | Host Pool Contributor **plus** Virtual Machine Contributor |
| `Add-AvdApplicationGroupAssignment` | User Access Administrator or Owner on the application group |
| `Get-AvdFslogixProfileHealth` | Read access to the profile share |
| `Get-AvdSessionLatencyReport` | Log Analytics Reader |

### Overlap with the Azure category

`Set-AzAvdSessionHostPower.ps1` and `Get-AzAvdUtilizationReport.ps1` live in `02-Azure` and also touch
AVD. They are separate workbook rows and are built separately. The subjects differ:

| Question | Script |
|---|---|
| Is the host **powered on**? | `Set-AzAvdSessionHostPower` (Azure) |
| Is the host **accepting connections**? | `Set-AvdSessionHostDrainMode` (here) |
| How **busy** is the pool? | `Get-AzAvdUtilizationReport` (Azure) |
| How **fast** are sessions, and are they failing? | `Get-AvdSessionLatencyReport` (here) |

---

## 2. Drain mode (#1) — the quiet risk

```powershell
.\Set-AvdSessionHostDrainMode.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod `
    -SessionHostName avd-01 -Drain
.\Set-AvdSessionHostDrainMode.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod `
    -SessionHostName avd-01                              # back into service
```

Drain mode **disconnects nobody**. Existing sessions continue and the host empties as people log off,
which is what makes it the graceful first step before maintenance.

It is also what makes the failure mode quiet. Drain the whole pool by accident and nothing happens —
until the next person tries to connect and finds nowhere to land. `-MaxDrainPercent` (default 50)
refuses any change that would leave less than half the pool taking connections.

---

## 3. Scaling (#4)

```powershell
.\Set-AvdHostPoolScale.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod `
    -PeakHostCount 10 -OffPeakHostCount 2 -MinimumHosts 2
```

`-MinimumHosts` is an absolute floor. It is checked against the computed target **before** anything
is stopped, and it wins over the schedule.

**A host with active sessions is drained, never stopped.** Stopping a host with users on it is a
disconnection, not a scale-down. The host is drained and picked up by a later run once it is empty.
Scale-down chooses the emptiest hosts first, so the fewest people are affected.

Azure's native **scaling plans** do load-based scaling properly and are the better answer for a pool
that needs it. This script is the simpler schedule-driven alternative for pools where a scaling plan
is more machinery than the problem deserves.

---

## 4. Idle sessions (#3) — prefer disconnect

```powershell
.\Disconnect-AvdUserSession.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod `
    -IdleThresholdHours 4                                        # report + approval

.\Disconnect-AvdUserSession.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod `
    -DisconnectOnly -ApprovalReference APR-...                   # nothing is lost

.\Disconnect-AvdUserSession.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod `
    -WarningMinutes 15 -ApprovalReference APR-...                # warn, wait, log off
```

**Consider `-DisconnectOnly` first.** It frees the connection without ending the session: the user
reconnects later to everything exactly as they left it. For most "reclaim idle sessions" goals that
is enough, and it has no downside.

A **logoff** ends the session and anything unsaved is gone. There is no rollback. The SOP requires
users be warned first, so the warning is the default path and the wait is real — the script sends an
on-screen message, sleeps for `-WarningMinutes`, then acts.

`-SkipWarning` exists for an emergency. It requires `-Reason` and logs that the SOP was bypassed.

---

## 5. Application group access (#6)

```powershell
.\Add-AvdApplicationGroupAssignment.ps1 -ResourceGroupName rg-avd `
    -ApplicationGroupName ag-finance -PrincipalGroupName 'AVD-Finance-Users' `
    -TicketReference REQ0012345
```

This row is **not** approval-gated, because the workbook says the ticket is the approval. That makes
`-TicketReference` **mandatory** here, unlike everywhere else in the library where it is optional
alongside an approval reference.

**Assign a group, not individual users.** It moves the access decision to group membership, where the
Access Review campaigns in the Security Cloud category can actually see and review it. Each
user-level assignment carries that advice on the result row.

---

## 6. FSLogix profile health (#5) — and what it deliberately does not do

```powershell
.\Get-AvdFslogixProfileHealth.ps1 -ProfileSharePath \\fs01\fslogix -MaxSizeGB 30 -IssuesOnly
```

Reports containers that are oversized, stale, zero-length, orphaned differencing disks, or locked and
unwritten for days.

**It does not mount a VHDX, and that is deliberate.** Mounting a profile container is itself a write
operation against the only copy of a user's desktop. Doing it on a schedule to look for problems is
how you cause them. Deep integrity checking belongs in a gated repair procedure with the user signed
out — which is what the workbook guardrail means by "repair gated".

A container held open by a live session is normal, not a fault. The report distinguishes that from
one held open and unwritten for weeks by looking at the age.

If the script reports zero containers, suspect permissions before you conclude the share is empty —
it says so in the log.

---

## 7. Image rollout (#2) — somebody has to sign it off

```powershell
# REPORT ONLY — resolves the image, raises an approval
.\Update-AvdHostPoolImage.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod `
    -GalleryImageId /subscriptions/.../versions/1.0.5

# Roll out, two hosts at a time
.\Update-AvdHostPoolImage.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod `
    -GalleryImageId /subscriptions/.../versions/1.0.5 `
    -ImageValidated -UatSignOffBy 'A. Rahman' -BatchSize 2 -ApprovalReference APR-...
```

`-ImageValidated` **and** `-UatSignOffBy` are both mandatory. Deciding a golden image is fit to put in
front of users needs somebody to log in to it and use the applications — no API establishes that. The
second parameter records *who*, because "validated" with no name attached is not a sign-off.

The image version is resolved in the Compute Gallery **before** the approval is raised, so nobody
approves a rollout of an image that may not exist. Each batch is **drained before it is touched**, and
the previous image id is logged as the rollback reference.

**Verify `-ApiVersion` first.** The session host configuration and update APIs moved through several
preview versions; the default is `2024-04-08-preview` and it is a placeholder.

---

## 8. Reimage (#7) — the destructive one

```powershell
# 1. Drain the host, in its own run
.\Set-AvdSessionHostDrainMode.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod `
    -SessionHostName avd-01 -Drain

# 2. Wait for it to empty

# 3. Reimage
.\Restore-AvdSessionHost.ps1 -ResourceGroupName rg-avd -HostPoolName hp-prod `
    -SessionHostName avd-01 -VmssName vmss-avd `
    -ApprovalReference APR-... -TicketReference CHG0012345 -Execute
```

**The script will not drain and reimage in one run.** A host that is not already in drain mode is
excluded, because draining and reimaging together gives sessions no time to end. Drain, wait, then
reimage — three steps, deliberately.

A host with active sessions is also excluded unless `-AllowActiveSessions` is passed, which cuts those
users off with no warning.

**What survives and what does not**, precisely:

| Survives | Destroyed |
|---|---|
| FSLogix profiles (they live on the share) | Files on the local disk |
| OneDrive and file server data | Locally installed applications |
| | Machine-level configuration |

There is no rollback. The host is left **in drain mode** after the reimage, deliberately — return it
to service with `Set-AvdSessionHostDrainMode` once it has registered and you have checked it.

Reimage is a scale set operation. A host pool built from standalone VMs is replaced by redeployment,
which this script does not do; those hosts are reported as excluded with the reason.

---

## 9. Latency reporting (#8)

```powershell
.\Get-AvdSessionLatencyReport.ps1 -ResourceGroupName rg-avd -WorkspaceName law-avd `
    -LookbackHours 24 -LatencyWarnMs 150
```

Four sections: latency by user, latency by session host, connection errors, connection volume.

Two things to read carefully:

- **Round-trip time is measured to the gateway, not to the application.** A good number rules the
  network *in* as a cause; it does not rule the application out. A user reporting a slow session with
  15 ms RTT has a problem somewhere else.
- **A missing table is reported as `NOT COLLECTED`, not as an empty section.** If AVD diagnostic
  settings are not sending `WVDConnections`, `WVDConnectionNetworkData` or `WVDErrors` to the
  workspace, the query fails — and that is a different finding from "no latency problems".

---

## 10. Audit trail

Every script logs through `Write-AutomationLog` — timestamp, level, the host or user touched, the
acting script — with credential-shaped strings redacted before anything is written.

Approval artifacts live in `%ProgramData%\ITAutomation\Approvals`. A reference is single-script and
expires; it cannot be replayed against a different action.

---

## 11. Known limitations

- **No script in this category has been executed against a real host pool.** Validation is static
  analysis (`Invoke-ScriptAnalyzer`, 0 findings), AST parse, and module-level unit tests with mocked
  inputs. Test against a lab pool first.
- **#2**: `-ApiVersion` is a placeholder (section 7).
- **#7**: VMSS-backed host pools only.
- **#5**: file-level inspection only, by design (section 6).
- **#3**: AVD reports session create time rather than a true idle clock, so "idle" here means session
  age. A user actively working in a long-lived session will appear alongside a genuinely abandoned
  one — which is another reason to prefer `-DisconnectOnly`.
