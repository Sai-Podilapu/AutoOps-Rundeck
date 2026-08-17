# SOP — Windows Server Automation

Standard operating procedure for the seven Windows Server scripts in
`Scripts/11-WindowsServer`.

**Source:** `Agent_Automation_Feasibility_Assessment.xlsx`, sheet *Windows Server*, use cases #1–#7.

---

## 1. Prerequisites

| Requirement | Detail |
|---|---|
| PowerShell | 5.1 or later on the machine running the scripts |
| Remoting | WinRM enabled on targets (`Enable-PSRemoting -Force`), TCP/5985 reachable |
| Module | `Modules/IT-Automation-Common.psm1` — imported automatically by each script |
| Config | `Config/config.json` — copy from `config.sample.json` and populate |
| Analyzer | `PSScriptAnalyzer` (development only, not needed at runtime) |

### Required permissions

| Script | Permission on target |
|---|---|
| `Get-WinServerDiskReport` | Read access to WMI/CIM |
| `Get-WinServerResourceReport` | Read access to WMI/CIM and performance counters |
| `Get-WinServerResourceSnapshot` | As above, plus System event log read |
| `Restart-WinServerService` | Service control rights (typically local Administrator) |
| `Sync-WinServerTime` | Local Administrator for `/resync`; remote execution rights for the query |
| `Restart-WinServerComputer` | Local Administrator, or `SeShutdownPrivilege` via a delegated group |
| `Stop-WinServerProcess` | Local Administrator |

Use a dedicated service account. Do not run these under a personal admin account — the audit trail
records the identity, and shared accounts make it useless.

---

## 2. Configuration

```powershell
Copy-Item .\Config\config.sample.json .\Config\config.json
notepad .\Config\config.json
```

Populate at minimum before first use:

| Key | Why it matters |
|---|---|
| `safety.protectedComputers` | **Populate before running the reboot script.** Ships as a placeholder. Domain controllers and anything else that must never be rebooted by automation belong here. |
| `safety.restartableServices` | The whitelist for service restart. Ships with `Spooler`, `W32Time`, `BITS`, `wuauserv`. Extend to match your SOP. |
| `safety.protectedProcesses` | The kill blacklist. Ships with the OS-critical set. **Do not remove entries** — terminating `lsass` or `csrss` bluescreens the host. |
| `maintenance.windowStartHour` / `windowEndHour` | The reboot window. Defaults 22:00–05:00. |
| `notifications.*` | Only needed if you use `-SendReport` or the approval-to-ITSM flow. |

`config.json` must never be committed to source control.

---

## 3. Running the read-only scripts

These three are safe to schedule unattended. They contain no write operations.

```powershell
# Use case #1 — disk capacity across the fleet
.\Scripts\11-WindowsServer\Get-WinServerDiskReport.ps1 `
    -ComputerName (Get-Content .\servers.txt) `
    -WarningThresholdPercent 20 -CriticalThresholdPercent 10 `
    -OutputFormat HTML

# Use case #2 — one-line utilisation summary per server
.\Scripts\11-WindowsServer\Get-WinServerResourceReport.ps1 `
    -ComputerName SRV01,SRV02 -OutputFormat CSV

# Use case #5 — deep single-host diagnostic pull
.\Scripts\11-WindowsServer\Get-WinServerResourceSnapshot.ps1 `
    -ComputerName SRV01 -IncludeEventLogErrors -OutputFormat JSON
```

**Expected output:** `[PSCustomObject]` collections on the pipeline. With `-OutputFormat` other than
`Console`, a file is also written to `reports.outputDirectory`.

Use JSON for the snapshot — CSV flattens away the nested process and volume detail, and the script
warns you when you ask for CSV.

---

## 4. Running the change scripts that need no approval

```powershell
# Use case #4 — restart a whitelisted service
.\Scripts\11-WindowsServer\Restart-WinServerService.ps1 -Name Spooler -ComputerName SRV01 -WhatIf   # dry run
.\Scripts\11-WindowsServer\Restart-WinServerService.ps1 -Name Spooler -ComputerName SRV01

# Use case #7 — check time sync (report only), then correct
.\Scripts\11-WindowsServer\Sync-WinServerTime.ps1 -ComputerName SRV01              # reports, changes nothing
.\Scripts\11-WindowsServer\Sync-WinServerTime.ps1 -ComputerName SRV01 -Resync
```

Both refuse work they are not permitted to do: `Restart-WinServerService` rejects any service absent
from the whitelist, and rejects protected services even if someone adds one to the whitelist by
mistake. `Sync-WinServerTime` changes nothing at all unless `-Resync` is passed.

---

## 5. The approval workflow

Applies to **use case #3 (reboot)** and **use case #6 (process kill)**. These will not act without a
valid approval reference. There is no bypass parameter.

### Step 1 — request

Run the script without `-ApprovalReference`. It produces the change set, writes an approval artifact
and prints a reference. **Nothing is changed.**

```powershell
.\Scripts\11-WindowsServer\Restart-WinServerComputer.ps1 `
    -ComputerName SRV01,SRV02 -Reason 'Monthly patching' -TicketReference CHG0012345
# WARNING: No reboot performed. Approval reference: APR-20260808220145-4471
```

### Step 2 — approve

A human — not the requester — opens the artifact and approves it:

```powershell
$ref  = 'APR-20260808220145-4471'
$path = "$env:ProgramData\ITAutomation\Approvals\$ref.json"
$a = Get-Content $path -Raw | ConvertFrom-Json

$a.ChangeSet          # review exactly what will happen

$a.State      = 'Approved'
$a.ApprovedBy = "$env:USERDOMAIN\$env:USERNAME"
$a.ApprovedAt = (Get-Date).ToString('o')
$a | ConvertTo-Json -Depth 6 | Set-Content $path -Encoding UTF8
```

### Step 3 — execute

```powershell
.\Scripts\11-WindowsServer\Restart-WinServerComputer.ps1 `
    -ComputerName SRV01,SRV02 -ApprovalReference APR-20260808220145-4471 -WaitForRecovery
```

### What the gate refuses

| Situation | Outcome |
|---|---|
| No reference supplied | REQUEST mode — nothing executes |
| Reference still `Pending` | Throws, logs `REFUSED to execute` |
| Reference expired (default 24h) | Throws |
| Reference raised for a **different script** | Throws — an approval for a report cannot be replayed against a reboot |
| Reference does not exist | Throws |
| Target on `safety.protectedComputers` | Skipped and logged, before approval is even considered |
| Outside the maintenance window (reboot) | Throws unless `-IgnoreMaintenanceWindow`, which is logged as an override |
| Process on `safety.protectedProcesses` (kill) | **Refused unconditionally — no override exists** |

Each of these is covered by a Pester test in `Tests/IT-Automation-Common.Tests.ps1`.

---

## 6. Rollback

| Script | Rollback |
|---|---|
| The three read-only scripts | Not applicable — nothing is changed |
| `Restart-WinServerService` | Prior state (status and start type) is captured and logged before the restart. Restore manually with `Set-Service` / `Start-Service` if needed. |
| `Sync-WinServerTime` | Not applicable. A resync moves the clock toward the authoritative source; it does not persist a config change. The script deliberately does not call `w32tm /config`. |
| `Restart-WinServerComputer` | **None — a reboot cannot be undone.** The mitigations are the approval gate, maintenance window and session check, all of which run *before* the action. |
| `Stop-WinServerProcess` | **None — a terminated process cannot be restored.** The blacklist and approval gate exist precisely because there is no recovery after the fact. |

---

## 7. Logging and audit

All scripts log to `%ProgramData%\ITAutomation\Logs\<ScriptName>_<yyyyMMdd>.log`, rotated at 90 days.

Each line carries a timestamp, level, script name, and — where an object was acted on — a `target='...'`
field, so an audit can answer *what did this run touch?* without parsing prose.

Credential-shaped strings are redacted before writing, in both logs and approval artifacts.

To reconstruct a change:

```powershell
Select-String -Path "$env:ProgramData\ITAutomation\Logs\*.log" -Pattern 'APR-20260808220145-4471'
```

---

## 8. Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| `Configuration file not found` | `config.json` not created | Copy from `config.sample.json` |
| `Refusing to run without a protected-process blacklist` | `safety.protectedProcesses` empty | Restore the list from the sample — the script fails closed by design |
| `Approval validation failed: ... is in state 'Pending'` | Nobody approved it | Complete Step 2 of the approval workflow |
| `Refusing to reboot outside the maintenance window` | Run started outside the window | Wait, or pass `-IgnoreMaintenanceWindow` (logged as an override) |
| `REFUSED - service is not in safety.restartableServices` | Service not whitelisted | Add it to the whitelist if your SOP permits |
| `Pre-flight failed ... tcp/5985 closed` | WinRM unreachable | `Enable-PSRemoting` on the target; check the firewall |
| Offset reports as `Unknown` | `w32tm` output not parsed | Localised or older Windows build. The script reports unknown rather than assuming zero — check manually with `w32tm /query /status` |
| Script exits 1 with results present | Some targets failed | Expected. Partial success is reported per target rather than hidden |

---

## 9. Scheduling

Only the **Read/Report + Low risk + no approval** scripts are suitable for unattended scheduling:

- `Get-WinServerDiskReport.ps1`
- `Get-WinServerResourceReport.ps1`
- `Get-WinServerResourceSnapshot.ps1`

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "D:\AutoOps\scripts\Scripts\11-WindowsServer\Get-WinServerDiskReport.ps1" -ComputerName (Get-Content D:\servers.txt) -OutputFormat HTML -SendReport'
$trigger = New-ScheduledTaskTrigger -Daily -At 6am
Register-ScheduledTask -TaskName 'ITAutomation-DiskReport' -Action $action -Trigger $trigger `
    -User 'CONTOSO\svc-itautomation' -RunLevel Highest
```

**Do not schedule the reboot or process-kill scripts unattended.** Their approval gate requires a
human, which is the point. Scheduling them in REQUEST mode to generate a nightly change proposal is
legitimate; scheduling them with a stored approval reference defeats the control.
