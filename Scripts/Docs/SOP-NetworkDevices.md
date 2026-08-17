# SOP — Network Device Automation

Standard operating procedure for the eighteen scripts in `Scripts/07-NetworkDevices`.

**Source:** `Agent_Automation_Feasibility_Assessment.xlsx`, sheet *Network Devices*, use cases #1–#18.

---

## 1. Read this first: what these scripts do and do not do

**They capture raw device output. They do not parse it.**

That is a deliberate scope decision, and it is the master prompt's own guidance: multi-vendor CLI
parsing is what Netmiko and NAPALM exist for. Those projects carry hundreds of maintained templates
per platform. A PowerShell reimplementation would be large, fragile, and worse — and it would be
worse in the specific way that matters, by returning confidently structured data that is quietly
wrong when a vendor changes a column header in a maintenance release.

So the PowerShell side does what it does well:

- reach the device over SSH,
- run the **right command for the declared vendor**,
- preserve the output **verbatim**,
- log what was run, what came back, and whether the device rejected it.

Structured parsing is attempted in **exactly three places** — CPU %, memory %, and ping success rate
— and only for platforms whose output format is stable and documented. Every other result row carries
`ParseNote = "Not parsed for this vendor - raw output only"`.

If you need structured multi-vendor data, feed these captures to a parser that already knows the
formats. That is the right division of labour, not a gap.

---

## 2. Prerequisites

| Requirement | Detail |
|---|---|
| PowerShell | 5.1 or later |
| Module | `Posh-SSH` — `Install-Module Posh-SSH -Scope AllUsers` |
| Shared module | `Modules/IT-Automation-Common.psm1` — imported automatically |
| Network | SSH (TCP/22 by default) to each device; `-Port` for anything else |

### Supported vendors

| `-Vendor` | Built-in command sets |
|---|---|
| `cisco-ios` | All 18 use cases |
| `cisco-nxos` | All 18 |
| `arista-eos` | All except #10 VLAN (see below) |
| `juniper-junos` | All except #10 VLAN |
| `generic` | **None** — requires `-Command` |

A vendor with no built-in set for a given script **throws**, lists the vendors that do have one, and
tells you to pass `-Command`. Commands are never guessed at for an unlisted platform.

`Set-NetInterfaceVlan` has no Junos implementation. Junos switching syntax differs enough from the
IOS-style platforms that assuming it would risk sending a command that means something else on a
production switch.

### Authentication

```powershell
$cred = Get-Credential            # or let the script prompt
.\Get-NetDeviceInventory.ps1 -DeviceName SW01 -Credential $cred
.\Get-NetDeviceInventory.ps1 -DeviceName SW01 -Credential $cred -KeyFile ~\.ssh\netops_ed25519
```

**No device password is read from configuration and none appears in any script.** The credential is
prompted for or passed in. With `-KeyFile`, the credential still supplies the username and its
password is used as the key passphrase.

Read-only capture needs only a read-only account. Only #8, #9, #10 and #15 need configuration
privilege — grant those to a separate account if your platform allows it.

---

## 3. Capture

```powershell
.\Get-NetDeviceInventory.ps1  -DeviceName SW01,SW02 -Vendor cisco-ios -RawOutputPath .\captures
.\Get-NetDeviceInterface.ps1  -DeviceName SW01 -OutputFormat CSV -OutputPath .\ports.csv
.\Get-NetDeviceHardware.ps1   -DeviceName CORE01,CORE02 -Vendor cisco-nxos
.\Get-NetDeviceLogTail.ps1    -DeviceName SW01 -LineCount 200
.\Get-NetDeviceLogSearch.ps1  -DeviceName SW01 -Keyword 'GigabitEthernet1/0/24'
```

**Use `-RawOutputPath`.** It writes one timestamped file per device per run. The raw capture is the
product of these scripts; console output is a convenience.

### Details worth knowing

- **A device that rejects a command answers on stdout, not with an error code.** The helper inspects
  the returned text for `% Invalid`, `% Incomplete` and `% Ambiguous` and marks that capture failed
  with the offending line. Trusting the exit status alone would record a rejection as a successful
  empty result — which is exactly the kind of quiet wrongness this category is built to avoid.
- **#17 takes the tail locally.** Platforms disagree on whether a "last N" argument exists and on
  which end it counts from, so `-LineCount` is applied here and means one thing everywhere.
- **#18 pushes the filter to the device**, so a large buffer is not shipped whole over SSH. The match
  is the platform's own — case sensitivity and pattern syntax are the device's, not a PowerShell
  regex.
- **#11 runs ping and traceroute from the device**, not from this host. That distinction is the whole
  point: a path that works from the automation host says nothing about the path the device would take.
- **#13 asks the device to resolve the prefix** against its own table. That is a different question
  from grepping a captured route dump, and it is the one worth asking during an incident.
- **#7**: the MAC table shows only what the switch has heard recently. A port absent from it is not
  proof that nothing is attached — the device may simply have been quiet past the ageing time.
- **#5** is largely for the finding that raises no alert: a failed redundant power supply causes no
  outage, it just quietly removes the redundancy.
- **#4** checks whether a device is logging anywhere other than its local buffer. The buffer is lost
  on reload — which is precisely when you want the logs.

---

## 4. Interface descriptions (#9) — safe, and still careful

```powershell
.\Set-NetInterfaceDescription.ps1 -DeviceName SW01 -Interface GigabitEthernet1/0/24 `
    -Description 'AP-Floor3-East' -SaveConfiguration
.\Set-NetInterfaceDescription.ps1 -DeviceName SW01 -Interface GigabitEthernet1/0/24 -Clear -WhatIf
```

Not approval-gated — the workbook calls it cosmetic and it is. It still **captures the previous
description before overwriting it**, because a port description is often the only record of what is
attached, and losing that silently would be a real cost for a change described as harmless.

Idempotent: a description already at the target value is skipped.

---

## 5. NTP (#15) — reports by default

```powershell
.\Set-NetDeviceNtp.ps1 -DeviceName SW01,SW02,SW03 -NtpServer 10.0.0.10,10.0.0.11
.\Set-NetDeviceNtp.ps1 -DeviceName SW01 -NtpServer 10.0.0.10,10.0.0.11 -Apply -SaveConfiguration
```

`-NtpServer` is your SOP standard and is mandatory — there is no shipped default. Without `-Apply`
the script only reports.

**`-RemoveUnlisted` is separately opt-in.** An NTP source that is not on your standard list is often
a deliberate local reference rather than drift, and stripping a device down to servers it cannot
reach leaves it worse than it started: unsynchronised, with no fallback.

Worth doing properly. Log timestamps that disagree across devices make an incident timeline useless.

---

## 6. VLAN change (#10) — the quiet one

```powershell
# REPORT ONLY — captures the rollback config and raises an approval
.\Set-NetInterfaceVlan.ps1 -DeviceName SW01 -Interface GigabitEthernet1/0/24 -VlanId 120 `
    -RollbackConfigPath .\rollback

# Apply an approved change
.\Set-NetInterfaceVlan.ps1 -DeviceName SW01 -Interface GigabitEthernet1/0/24 -VlanId 120 `
    -RollbackConfigPath .\rollback -ApprovalReference APR-... -TicketReference CHG0012345
```

**A VLAN change is quieter than a shutdown and often worse to diagnose.** The link stays up, the port
counters keep incrementing, and the device on the other end simply stops being able to reach
anything — no gateway, no DHCP scope, no address.

Three protections:

1. **The rollback is a real artifact.** The complete pre-change interface configuration is written to
   `-RollbackConfigPath` *while the port still works*, and logged as well. Re-applying that block
   restores the port exactly. Always pass `-RollbackConfigPath`; without it the rollback exists only
   in the log, and the script warns you about that.
2. **The target VLAN is verified to exist on the device first.** Moving a port to a VLAN the switch
   does not have is a silent black hole — the config accepts it and the traffic goes nowhere.
3. **Trunk ports are excluded** unless `-IncludeTrunkPorts` is passed. Setting an access VLAN on a
   trunk changes its mode and drops every VLAN it was carrying.

Without `-SaveConfiguration`, a device reload also reverts the change. That can be a useful safety
net during a risky change — or an unpleasant surprise weeks later. Decide deliberately.

---

## 7. Interface shutdown (#8) — the destructive one

```powershell
# REPORT ONLY — shows what is on the port and raises an approval
.\Set-NetInterfaceState.ps1 -DeviceName SW01 -Interface GigabitEthernet1/0/24 `
    -State Shutdown -TicketReference INC0012345

# Shut an approved port
.\Set-NetInterfaceState.ps1 -DeviceName SW01 -Interface GigabitEthernet1/0/24 `
    -State Shutdown -ApprovalReference APR-... -TicketReference INC0012345 -Execute
```

The guardrail asks for **ticket + interface confirmation**, and both are enforced rather than
documented:

- **Ticket.** The script throws without `-TicketReference`. A port shut with no ticket has no
  confirmation trail, which is the thing the guardrail is asking for.
- **Interface confirmation.** Wildcards are refused by `ValidatePattern`. The interface config is
  read back and a port returning nothing is excluded — it may not exist on that device. And the
  change set carries the current status, the port description and **what the MAC table has heard on
  that port**, so the approver is looking at what is *connected* rather than at an interface name.

Uplink and trunk ports are excluded unless `-IncludeUplinkPorts` is passed. Detection is by
description keyword, `switchport mode trunk`, and interface naming. It is a heuristic, and it is
tuned to fail toward exclusion — a port wrongly excluded costs you one flag; an uplink wrongly shut
costs everything behind it.

On top of that: report-only by default, plus `-Execute`, plus a valid approval reference,
`ConfirmImpact = 'High'`.

**Rollback:** the full pre-change interface configuration is logged before the change. Re-apply the
opposite state to revert. Without `-SaveConfiguration`, a reload also reverts it.

---

## 8. How configuration is actually sent

Configuration goes through an **interactive shell stream**, not one-shot exec commands. A device will
not accept `configure terminal` as a single command — it needs a channel that stays in config mode.

The **full transcript** is captured: what was sent and what the device said back, line by line. Any
line matching a rejection pattern (`%`, `invalid input`, `syntax error`, `command rejected`) fails
the change rather than being written off as noise, and the transcript goes into the audit log either
way.

If a change fails partway, read the transcript. It shows exactly which line the device refused and
what state the session was left in.

---

## 9. Audit trail

Every script logs through `Write-AutomationLog` — timestamp, level, the device and interface touched,
the acting script — and credential-shaped strings are redacted before anything is written.

Approval artifacts live in `%ProgramData%\ITAutomation\Approvals`. A reference is single-script and
expires; it cannot be replayed against a different action.

SSH sessions are closed on **every** exit path, including the no-candidates, request-approval and
report-only early returns.

---

## 10. Known limitations

- **No script in this category has been executed against a real device.** Validation is static
  analysis (`Invoke-ScriptAnalyzer`, 0 findings), AST parse, and module-level unit tests with mocked
  inputs. Test against a lab switch before touching production.
- **Parsing is minimal by design** (section 1). If you need structured inventory across vendors, use
  Netmiko or NAPALM and feed it these captures.
- **Uplink detection in #8 is a heuristic**, not a fact the device reports. Review the excluded list.
- **No Junos VLAN support** in #10.
- The settle delay between configuration lines is fixed at 800 ms. A slow or heavily loaded device
  may need more; the transcript will show a truncated response if so.
