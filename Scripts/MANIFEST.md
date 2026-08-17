# MANIFEST — IT Automation Script Library

Generated index mapping workbook use cases to script files.

**Source:** `Agent_Automation_Feasibility_Assessment.xlsx` — 213 use cases across 13 category sheets.
**Last updated:** 2026-08-09

---

## Progress

| Category | Sheet count | Scripts built | Status |
|---|--:|--:|---|
| Windows Server | 7 | 7 | Complete |
| Hyper-V | 12 | 12 | Complete |
| VMware OnPrem | 13 | 13 | Complete |
| AWS | 22 | 22 | Complete |
| Azure | 32 | 32 | Complete |
| Azure AVD | 8 | 8 | Complete |
| M365 | 22 | 22 | Complete |
| Exchange & O365 | 25 | 25 | Complete |
| AD & Identity | 12 | 12 | Complete |
| Backup Commvault | 9 | 9 | Complete |
| OCI | 15 | 15 | Complete |
| Network Devices | 18 | 18 | Complete |
| Security Cloud | 18 | 18 | Complete |
| **Total** | **213** | **213** | **100%** |

---

## Foundation

| Component | Path | Status | Validation |
|---|---|---|---|
| Shared module | `Modules/IT-Automation-Common.psm1` | ✅ Built | 24 Pester tests pass |
| Sample config | `Config/config.sample.json` | ✅ Built | Validated by Pester |
| Module tests | `Tests/IT-Automation-Common.Tests.ps1` | ✅ Built | 24/24 pass |

**Exported functions:** `Write-AutomationLog`, `Connect-AutomationPlatform`, `Send-AutomationReport`,
`New-ApprovalRequest`, `Test-ApprovalReference`, `Export-AutomationResult`, `Test-Prerequisite`,
`Get-AutomationConfig`.

---

## 11 — Windows Server (7 of 7)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | Disk Reports | `Get-WinServerDiskReport.ps1` | Read / Report | Low | No | ✅ Built |
| 2 | Resource Utilization Report | `Get-WinServerResourceReport.ps1` | Read / Report | Low | No | ✅ Built |
| 3 | Windows Server Reboot | `Restart-WinServerComputer.ps1` | Change / Write | Medium | **Yes** | ✅ Built |
| 4 | Windows Service Restart | `Restart-WinServerService.ps1` | Change / Write | Low | No | ✅ Built |
| 5 | Windows Resource Utilization Pull | `Get-WinServerResourceSnapshot.ps1` | Read / Report | Low | No | ✅ Built |
| 6 | Windows Process Kill | `Stop-WinServerProcess.ps1` | Change / Write | Medium | **Yes** | ✅ Built |
| 7 | Windows Time Sync | `Sync-WinServerTime.ps1` | Change / Write | Low | No | ✅ Built |

### Safety controls implemented, by row

| # | Guardrail from column L | How it is enforced in code |
|--:|---|---|
| 1 | Read-only | No write/modify/delete cmdlet appears in the script. Safe to schedule. |
| 2 | Read-only | As above. |
| 3 | Reboot causes downtime; ticket/maintenance-window driven | Refuses to act without a valid `-ApprovalReference` raised for this script. Refuses outside the configured maintenance window unless `-IgnoreMaintenanceWindow` is passed, which is logged as an override. Hard protected-computer list from config. `ConfirmImpact = 'High'`. Optional active-session check. |
| 4 | Common L1 fix; whitelist of restartable services in SOP | Whitelist enforced in code from `safety.restartableServices`; a service not on it is refused. A separate protected-service blacklist wins over the whitelist. Prior state captured and logged before restart; end state verified after. |
| 5 | Read-only | No write/modify/delete cmdlet appears in the script. |
| 6 | Killing wrong process disrupts apps; confirm PID/name + protected-process blacklist | Protected-process blacklist from config, refused **unconditionally with no override parameter**. Wildcards rejected by `ValidatePattern`. Every candidate PID logged before action. Requires a valid `-ApprovalReference`. `ConfirmImpact = 'High'`. |
| 7 | Low-risk config | Report-only by default; changes nothing unless `-Resync` is passed. ShouldProcess-aware. |

---

## 06 — Security Cloud (18 of 18)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | Azure Defender for Cloud Alert Triage | `New-DefenderAlertTicket.ps1` | Change / Write | Low | No | Built |
| 2 | Microsoft Sentinel SOAR Playbook - Phishing | `Invoke-SentinelPhishingTriage.ps1` | Change / Write *(assist-only)* | Medium | **Yes** | Built |
| 3 | Azure Entra ID Risky User Remediation | `Invoke-EntraRiskyUserRemediation.ps1` | Change / Write *(assist-only)* | **High** | **Yes** | Built |
| 4 | Privileged Account Usage Report | `Get-PrivilegedAccountUsageReport.ps1` | Read / Report | Low | No | Built |
| 5 | Cloud Security Posture (CSPM) Report | `Get-MultiCloudPostureReport.ps1` | Read / Report | Low | No | Built |
| 6 | Vulnerability Scan Trigger & Report | `Start-VulnerabilityScan.ps1` | Change / Write | Low | No | Built |
| 7 | SSL/TLS Certificate Expiry Monitor | `Get-CertificateExpiryReport.ps1` | Read / Report | Low | No | Built |
| 8 | Firewall Rule Change Audit | `Get-FirewallRuleChangeAudit.ps1` | Read / Report | Low | No | Built |
| 9 | CIS Benchmark Compliance Check | `Get-CisBenchmarkCompliance.ps1` | Read / Report | Low | No | Built |
| 10 | Endpoint EDR Alert Auto-Triage | `Invoke-EdrAlertTriage.ps1` | Change / Write *(assist-only)* | **High** | **Yes** | Built |
| 11 | Identity Governance Access Review | `Start-AccessReviewCampaign.ps1` | Change / Write *(assist-only)* | Low | No | Built |
| 12 | SIEM Log Source Health Check | `Get-SiemLogSourceHealth.ps1` | Read / Report | Low | No | Built |
| 13 | Dark Web Credential Monitoring Alert | `Get-BreachCredentialAlert.ps1` | Read / Report | Low | No | Built |
| 14 | Zero Trust Network Access Policy Audit | `Get-ZeroTrustPolicyAudit.ps1` | Read / Report *(assist-only)* | Low | No | Built |
| 15 | Cloud WAF Rule Update Automation | `Update-CloudWafRuleSet.ps1` | Change / Write *(assist-only)* | **High** | **Yes** | Built |
| 16 | Patch Tuesday Compliance Report | `Get-PatchComplianceReport.ps1` | Read / Report | Low | No | Built |
| 17 | Data Exfiltration Detection Alert | `Get-DataExfiltrationAlert.ps1` | Read / Report *(assist-only)* | Low | No | Built |
| 18 | Service Account Password Rotation | `Update-ServiceAccountSecret.ps1` | Change / Write *(assist-only)* | **High** | **Yes** | Built |

**Every row on this sheet is feasibility "Partial" and eight are agent-assist** — the highest
proportion of any category. That shape is the category: security work automates the gathering,
enrichment and correlation, and stops at the judgement.

### Safety controls implemented, by row

| # | Guardrail from column L | How it is enforced in code |
|--:|---|---|
| 2 | Playbook auto-handles high-confidence known patterns; **ambiguous phishing verdicts and sender-block decisions need an analyst** | Both exclusions are structural. An incident is eligible for automatic closure **only** if it matches an entry in the mandatory `-KnownPatternFile`; everything else stays open and is reported, because a phishing incident closed wrongly is a real one nobody looks at again. **Sender blocking is not performed under any flag** — where the evidence supports one the report names the sender and says the decision is the analyst's. Blocking a sender has effects well beyond the incident that prompted it. |
| 3 | Auto-remediate only high-confidence risk signals; medium/ambiguous go to analyst — **false positive lockouts hurt users** | `-MinimumRiskLevel` has a **single-value ValidateSet** (`high`). Medium and low risk users are reported and are structurally not actionable — a parameter that could be widened would not honour the guardrail. The three actions are ordered by cost-when-wrong: `RevokeSessions` (default, costs a re-authentication), `ConfirmCompromised`, and `BlockSignIn` — which needs `-LockoutAccepted` **on top of** the approval, because that is the one that costs a real user their working day. |
| 10 | Enrichment, correlation & ticketing automatable; **isolating a production server is an analyst decision, not a rule** | The split follows the guardrail exactly. Enrichment, device correlation and ticketing run for every qualifying alert. **Isolation runs for nothing unless a device is named in `-IsolateDevice`, `-ProductionImpactAssessed` is passed, and the approval is valid** — three separate human acts. There is deliberately **no severity threshold that triggers isolation**, because that would be precisely the rule the guardrail says must not exist. Devices matching `-ProductionNamePattern` are refused outright, and that refusal cannot be overridden by a parameter. |
| 11 | Agent launches campaigns, chases reviewers, compiles results; **the access keep/revoke decisions belong to managers by design** | The one row using the engine's `assist_action` exception (see below). Campaign creation, reviewer chasing and result compilation are automated. **`autoApplyDecisionsEnabled` is set to `false`** on every campaign this script creates, and the script never sets a decision on anyone's behalf — the keep/revoke call is made by each manager in the review UI, days later, which is not something this script could gate even in principle. |
| 15 | Managed rule-set updates automatable **in staged mode**; custom rule changes risk blocking legit traffic — **human validates detection-mode results first** | The staging is the control. A managed rule set update **always lands in Detection mode**, where it logs what it would block and blocks nothing. Promotion to Prevention is a separate run requiring `-PromoteToPrevention` **and** `-DetectionResultsValidated`. **Custom rules are never modified** — they are counted, named and left alone, because their blast radius is entirely application-specific. |
| 18 | Vault-managed accounts rotate automatically; **unmanaged/legacy accounts need human dependency discovery first or things break** | `-DependencyInventoryFile` is mandatory and is the human half: an application absent from it is reported as needing discovery and is **structurally not rotatable**. Rotating a secret is trivial; knowing what stops working when you do is not, and that knowledge does not live in any API. `-RemoveOldSecret` is off by default so both secrets work until consumers have moved — the overlap window is what turns a rotation from an outage into a change. |
| 1 | Auto-create ITSM tickets for HIGH alerts; **ticketing is safe** | Safe, and therefore ungated — but only if it is idempotent. The ticketed alert set is **persisted to a state file** and written immediately after each ticket, so a failure mid-batch cannot cause a re-ticket next run. `-MaxTickets` caps a single run and logs when it truncates. The dangerous failure here is not one wrong ticket, it is a thousand right ones. |

### Where these scripts refuse to fabricate a number

Three rows ask for an aggregate that would be easy to produce and wrong:

- **#5 CSPM produces NO blended score.** Azure Secure Score, AWS Security Hub and OCI Cloud Guard
  measure different control sets on different scales with different weightings. Averaging them gives
  a number that moves for reasons nobody can explain and means nothing to any of the three teams.
  Each cloud is reported on its own scale; **finding counts by severity — which are comparable — are
  totalled.** A cloud that could not be queried is reported as `NOT QUERIED`, because a missing cloud
  silently improves any total it is left out of.
- **#16 patch compliance** reports a combined percentage over **only the platforms that answered**,
  and names them. A platform that failed is `NOT QUERIED`, not counted as zero machines — dropping an
  estate from the denominator makes the number go up, which is the wrong direction for a compliance
  figure to move by accident.
- **#9 CIS** reports what the cloud's own policy engine already evaluated. It does not implement its
  own benchmark checks. If no CIS initiative is assigned, it says **nothing is being evaluated**
  rather than reporting zero failures — which would read as a clean bill of health for a benchmark
  nobody is running.

### Other honesty notes

- **#12 SIEM health**: a source silent longer than the lookback window has no recent record to be
  late, so it never appears in a last-seen query. `-ExpectedDataType` is the only way to distinguish
  *quiet* from *gone*, and that difference is the failure this check exists for.
- **#7 certificates** check what is **served**, by opening a TLS connection — not what is stored. A
  certificate renewed in Key Vault but never bound to the listener passes every inventory check and
  still takes the site down. Certificate validation is deliberately not enforced during the probe, so
  an already-expired certificate is reported as expired rather than as an unreachable host.
- **#13 HIBP**: a 404 means "not in any breach" and is handled as the good answer, not an error. Every
  finding carries the caveat that appearing in a dataset does not establish that the *corporate*
  password was the one exposed.
- **#17 exfiltration**: volume is not evidence. Backup, replication, video upload and genuine theft
  look identical in a byte count, and the most alarming-looking entries are usually the scheduled
  ones. Every finding carries an `InvestigatorNote` with the benign explanation and `Verdict = NONE`.
- **#14 Zero Trust**: a policy in report-only mode is reported as **NOT in force**, because that is
  what it is. This overlaps deliberately with the M365 Conditional Access audit — that one
  inventories policies, this one tests them against a Zero Trust expectation.

### Engine exception: `assist_action`

Use case #11 is the **only** row in the library using this flag, and it is worth recording why.

The engine's rule is that an assist-only row with no approval gate stops at a report, because there
is no gate through which a human could authorise an action. #11 breaks that: it is marked
`Change / Write` with **no** approval required, and its guardrail says explicitly that the agent
*launches* campaigns. The automatable half is itself a write; the human judgement — keep or revoke —
is made by each manager inside the review UI days later, somewhere this script could not gate even in
principle.

Forcing it to report-only would have contradicted the workbook. So the engine grew one documented
escape hatch, `assist_action`, used here and nowhere else. The corresponding safety is that
`autoApplyDecisionsEnabled` is `false` on every campaign created.

---

## 07 — Network Devices (18 of 18)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | Device Inventory Details | `Get-NetDeviceInventory.ps1` | Read / Report | Low | No | Built |
| 2 | Device CPU Details | `Get-NetDeviceCpu.ps1` | Read / Report | Low | No | Built |
| 3 | Device Memory Details | `Get-NetDeviceMemory.ps1` | Read / Report | Low | No | Built |
| 4 | Device Logging Details | `Get-NetDeviceLoggingConfig.ps1` | Read / Report | Low | No | Built |
| 5 | Device Hardware Details | `Get-NetDeviceHardware.ps1` | Read / Report | Low | No | Built |
| 6 | Device Interface Details | `Get-NetDeviceInterface.ps1` | Read / Report | Low | No | Built |
| 7 | Display MAC-to-Interface Mapping | `Get-NetDeviceMacTable.ps1` | Read / Report | Low | No | Built |
| 8 | Enable/Disable Interface Ports | `Set-NetInterfaceState.ps1` | **DESTRUCTIVE** | **High** | **Yes** | Built |
| 9 | Add/Remove Port Description | `Set-NetInterfaceDescription.ps1` | Change / Write | Low | No | Built |
| 10 | Add/Remove Port VLAN | `Set-NetInterfaceVlan.ps1` | Change / Write | **High** | **Yes** | Built |
| 11 | Traceroute & Ping Test | `Test-NetDeviceReachability.ps1` | Read / Report | Low | No | Built |
| 12 | Display IP Route (general) | `Get-NetDeviceRouteTable.ps1` | Read / Report | Low | No | Built |
| 13 | Display IP Route (specific IP/network) | `Get-NetDeviceRouteForPrefix.ps1` | Read / Report | Low | No | Built |
| 14 | Resource Utilization - CPU/Mem/Disk | `Get-NetDeviceResourceUtilization.ps1` | Read / Report | Low | No | Built |
| 15 | Device Time Sync (NTP) | `Set-NetDeviceNtp.ps1` | Change / Write | Low | No | Built |
| 16 | View Process ID & Resource Consumption | `Get-NetDeviceProcess.ps1` | Read / Report | Low | No | Built |
| 17 | Display Last 100 Log Lines | `Get-NetDeviceLogTail.ps1` | Read / Report | Low | No | Built |
| 18 | Display Last 100 Logs w/ Keyword Filter | `Get-NetDeviceLogSearch.ps1` | Read / Report | Low | No | Built |

### Scope decision: raw capture, not parsing

**This category is deliberately narrower than the others, on the master prompt's own instruction.**
Section 4 of the prompt states that Python/Netmiko is the better fit for multi-vendor CLI parsing and
that the PowerShell version should stay simple — command execution and raw capture. That is what
these 18 scripts do:

- They reach the device over SSH, run the **right command for the declared vendor**, and preserve
  the output **verbatim**.
- `-RawOutputPath` writes one timestamped capture file per device. **The raw capture is the product.**
- Structured parsing is attempted in exactly three places — CPU %, memory %, and ping success rate —
  and only for the platforms whose output format is stable and documented. Every other row carries
  `ParseNote = "Not parsed for this vendor - raw output only"`. Nothing is matched against a hopeful
  regex.
- A vendor with no built-in command set **throws with the list of supported vendors and tells the
  operator to pass `-Command`**. Commands are never guessed at for an unlisted platform.

Vendors with built-in command sets: `cisco-ios`, `cisco-nxos`, `arista-eos`, `juniper-junos`, plus
`generic` (which requires `-Command`).

### Safety controls implemented, by row

| # | Guardrail from column L | How it is enforced in code |
|--:|---|---|
| 8 | **Shutting the wrong port causes outage; ticket + interface confirmation before change** | Both halves are enforced. **Ticket:** the script *throws* without `-TicketReference` — a port shut with no ticket has no confirmation trail. **Interface confirmation:** the interface name is `ValidatePattern`-constrained so **wildcards are refused**, the interface configuration is read back and a port that returns nothing is excluded (it may not exist on that device), and the change set carries the current status, the port description and **what the MAC table has heard on that port** — so an approver is looking at what is connected, not at an interface name. A port whose description, `switchport mode trunk` line or name suggests an uplink is excluded unless `-IncludeUplinkPorts` is passed. Report-only + `-Execute` + approval reference. The full pre-change interface config is logged before the change as the rollback. |
| 10 | VLAN change can drop connectivity; **approval gate + rollback config** | Approval-gated, and the rollback is a real artifact: the complete pre-change interface configuration is written to `-RollbackConfigPath` **while the port still works**, and logged as well. Re-applying that block restores the port exactly. Two extra brakes the guardrail does not name but the failure mode demands: the **target VLAN is verified to exist on the device first** (moving a port to a VLAN the switch does not have is a silent black hole), and a trunk port is excluded unless `-IncludeTrunkPorts` is passed, because setting an access VLAN on a trunk changes its mode and drops every VLAN it carried. |
| 9 | Cosmetic config change; safe | Not gated, correctly. It still **captures the previous description before overwriting it** — a port description is often the only record of what is attached, and losing it silently would be a real cost for a change described as harmless. Idempotent: a description already at the target value is skipped. |
| 15 | Low-risk config; **standard NTP servers in SOP** | `-NtpServer` is mandatory and is the SOP standard the device is compared against. **Reports by default and changes nothing without `-Apply`.** Removing unlisted servers is separately opt-in via `-RemoveUnlisted`, because an unlisted NTP source is often a deliberate local reference rather than drift, and stripping a device down to servers it cannot reach leaves it worse than it started. |

### Notes on the read-only rows

- **#17 takes the tail locally, not on the device.** Platforms disagree on whether a "last N"
  argument exists and on which end it counts from; trimming here makes `-LineCount` mean one thing
  everywhere.
- **#18 pushes the filter to the device**, so a large log buffer is not shipped whole over SSH. The
  match is the platform's — case sensitivity and pattern syntax are the device's, not a PowerShell
  regex.
- **#11 runs ping and traceroute *from the device*,** not from the automation host. A path that works
  from here says nothing about the path the device would take.
- **#13 asks the device to resolve the prefix** against its own table rather than text-searching a
  captured route dump.
- **#7** notes that the MAC table only shows what the switch has heard recently — an empty result for
  a port is not evidence that nothing is attached.
- **#5** exists mostly for the finding that produces no alert: a failed redundant power supply causes
  no outage, it just quietly removes the redundancy.

### Platform note

`Posh-SSH` is the only module dependency. Two details worth knowing:

- **A device that rejects a command answers on stdout, not with a non-zero exit status.** The helper
  inspects the returned text for `% Invalid` / `% Incomplete` / `% Ambiguous` and marks the capture
  failed. Trusting the exit code alone would record a rejection as a successful empty result.
- **Configuration goes through an interactive shell stream, not one-shot exec.** A device will not
  accept `configure terminal` as a single command. The **full transcript** — what was sent and what
  the device said back — is returned and logged, and any line matching a rejection pattern fails the
  change rather than being written off as noise.
- Connection settings are gathered into one context object and passed explicitly to every helper.
  Reaching `$Port` or `$KeyFile` from inside a nested function by dynamic scoping works, but it hides
  the dependency from a reader and from static analysis alike.

---

## 08 — Backup Commvault (9 of 9)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | Backup Job Status Check | `Get-CvBackupJobStatus.ps1` | Read / Report | Low | No | Built |
| 2 | Run a Backup | `Start-CvBackupJob.ps1` | Change / Write | Low | No | Built |
| 3 | Re-run a Failed Job | `Restart-CvFailedJob.ps1` | Change / Write | Low | No | Built |
| 4 | Display Current Active Jobs | `Get-CvActiveJob.ps1` | Read / Report | Low | No | Built |
| 5 | Display Scheduled Jobs (next 2 days) | `Get-CvScheduledJob.ps1` | Read / Report | Low | No | Built |
| 6 | Eject Tape from Drive | `Export-CvTapeMedia.ps1` | Change / Write *(assist-only)* | Medium | **Yes** | Built |
| 7 | Commvault Backup Health Check | `Get-CvBackupHealthReport.ps1` | Read / Report | Low | No | Built |
| 8 | Commvault Backup Configuration | `Set-CvSubclientConfiguration.ps1` | Change / Write *(assist-only)* | **High** | **Yes** | Built |
| 9 | Commvault Backup Restoration | `Restore-CvBackupData.ps1` | **DESTRUCTIVE** *(assist-only)* | **High** | **Yes** | Built |

### Safety controls implemented, by row

| # | Guardrail from column L | How it is enforced in code |
|--:|---|---|
| 3 | Safe retry; **window-aware per SOP** | The window is enforced, not documented. Outside `-WindowStartHour`/`-WindowEndHour` the script **throws** rather than queueing; `-IgnoreWindow` overrides it for a ticketed catch-up and logs a WARN when it does. The wrap-around case (22:00—05:00) is handled explicitly — a naive range test would treat the entire night as outside the window. `-ExcludeReasonPattern` refuses to retry failures a retry cannot fix (expired licence, bad credential, missing path); those burn a backup window and fail identically. `-MaxJobs` caps a run, and the count of jobs it dropped is logged rather than silently truncated. |
| 6 | Software eject via API automatable; **physically removing & vaulting the tape needs a person at the datacenter** | Assist-only **and** approval-gated. The API half runs; the script then produces a **pick list** naming every barcode and slot, and both the log line and the result row state that physical removal and vaulting are still outstanding. Mounted or in-use media are excluded — ejecting a cartridge mid-write is the failure this prevents. The export endpoint path is a **parameter with a placeholder default**, because it varies by Commvault version; it was not guessed at silently. |
| 8 | Bulk config changes via API possible; **backup/protection DESIGN decisions (what, how often, retention) are human** | Assist-only and approval-gated. Two independent brakes: nothing is written unless the property is named in `-ApplyProperty`, and the properties that *encode a design decision* — storage policy, retention, backup level, schedule, content paths — are listed in `-DesignProperty` and refused outright unless `-DesignApproved` is passed. `-DesignApproved` additionally requires a `-Reason` naming the design authority. Drift in a design property is still **reported**, just not actionable. |
| 9 | Agent executes restore per ticket; **choosing target, version, in-place vs out-of-place, and validating restored data is human-verified** | The category's only Destructive row, and nothing is defaulted. An out-of-place restore requires **both** `-DestinationClient` and `-DestinationPath`; `-InPlace` is mutually exclusive with them and additionally requires `-OverwriteConfirmed`. The version must be stated as `-FromJobId` or `-PointInTime` — **there is no "latest" default**, because a restore that silently picked "latest, in place" is precisely the accident this gate exists to prevent. On top of that: report-only by default, plus `-Execute`, plus a valid approval reference. Rollback is documented as **none for in-place**. Validating the restored data is explicitly not performed and is stated as outstanding in the result row and the success log. |

### Platform note

Commvault ships no first-party PowerShell module, so all nine scripts call the v11 REST API through
`Invoke-RestMethod`. A shared session prologue is compiled into each script:

- **`-AccessToken` (SecureString) is preferred over `-Credential`.** Commvault's `/Login` requires the
  password base64-encoded, so a credential login means the secret exists as a managed string for the
  duration of one request. The BSTR is zeroed in a `finally` block whether or not the call succeeds,
  and the encoded copy is removed immediately after the request body is built. `-AccessToken` avoids
  the conversion entirely.
- **No password is ever read from configuration.** `config.json` supplies only the web service URL.
- **The session is closed on every exit path** — including the no-candidates, request-approval and
  report-only early returns, not just the success path. This required a `cleanup` hook in the
  generator; a logout emitted only at the end would have leaked a token on three paths out of four.

---

## 09 — Hyper-V (12 of 12)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | VM Snapshot Creation | `New-HvVmCheckpoint.ps1` | Change / Write | Low | No | Built |
| 2 | VM Snapshot Deletion | `Remove-HvVmCheckpoint.ps1` | Change / Write | Medium | No | Built |
| 3 | VM Power On/Off/Restart | `Set-HvVmPowerState.ps1` | Change / Write | Low | No | Built |
| 4 | New VM Provisioning | `New-HvVirtualMachine.ps1` | Change / Write | Medium | **Yes** | Built |
| 5 | Host Health Check | `Get-HvHostHealthReport.ps1` | Read / Report | Low | No | Built |
| 6 | VM Live Migration | `Move-HvVirtualMachine.ps1` | Change / Write | **High** | **Yes** | Built |
| 7 | Replication Health Check | `Get-HvReplicationHealth.ps1` | Read / Report | Low | No | Built |
| 8 | Disk Expand | `Resize-HvVirtualDisk.ps1` | Change / Write | Medium | **Yes** | Built |
| 9 | VM Inventory Report | `Get-HvVmInventoryReport.ps1` | Read / Report | Low | No | Built |
| 10 | NIC Add/Remove | `Set-HvVmNetworkAdapter.ps1` | Change / Write | Medium | **Yes** | Built |
| 11 | Cluster Node Health | `Get-HvClusterNodeHealth.ps1` | Read / Report | Low | No | Built |
| 12 | ISO Mount/Unmount | `Set-HvVmDvdDrive.ps1` | Change / Write | Low | No | Built |

### Safety controls implemented, by row

| # | Guardrail from column L | How it is enforced in code |
|--:|---|---|
| 1 | Checkpoint before patching; additive | `-SkipIfRecentHours` makes a re-run idempotent instead of stacking checkpoints. |
| 2 | Age-based (>7 days) rule makes this safe; merge impact noted in SOP | `-MinimumAgeDays` defaults to 7 exactly as the guardrail specifies; `-KeepLatest` always preserves the newest N per VM. Merge IO is called out in `.NOTES` and the SOP. |
| 3 | Controlled power ops with logging | Graceful shutdown by default; `TurnOff` (the hard power cut) is an explicit operator choice and never a fallback. Waits for and verifies the requested end state within `-TimeoutSeconds`. |
| 4 | Capacity impact; approve spec before deploy | Host free-space checked against `-MinimumHostFreeGB` and the provision refused if it would breach it. Duplicate VM name refused. Approval-gated. VM left powered off. |
| 5 | CPU/memory/network/storage report | Read-only. Reports vCPU overcommit ratio and assigned-vs-physical memory, not just raw counters. |
| 6 | Zero-downtime in theory, but failures impact prod VMs; approval + maintenance window | Live migration enabled verified on **both** hosts before starting; destination free memory checked against the VM's assigned memory; duplicate name on destination refused; post-migration verification reports where the VM actually ended up. Approval-gated, Risk=High so pre-flight runs first. |
| 7 | Verify replication lag and state | Read-only. Flags replication that is enabled but lagging beyond `-MaxLagMinutes` — the failure that looks healthy in the console. |
| 8 | Expanding is safe-ish but touches guest partition; ticket-driven | **Refuses to shrink** — expansion only. Reports that the guest partition still needs extending, and says so in the result object rather than implying the job is done. Approval-gated. |
| 9 | Export CPU/RAM/disk/network inventory | Read-only. Nested disk and NIC detail; JSON recommended over CSV. |
| 10 | Network change on VMs; ticket + approval | **Refuses to remove the last remaining adapter** (that isolates the VM). Idempotent on both add and remove. Approval-gated. Rollback note warns that a re-added NIC gets a new MAC. |
| 11 | Node status, quorum, resource health | Read-only. Reports the **quorum failure margin**, not just current quorum — one failure away from losing the cluster is a different fact from quorum held. |
| 12 | Low-risk, reversible | Idempotent both ways. Logs what was mounted where, because a forgotten ISO blocks live migration. |

---

## 10 — VMware OnPrem (13 of 13)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | Create VM Snapshot | `New-VmwareVmSnapshot.ps1` | Change / Write | Low | No | Built |
| 2 | VM Snapshot Deletion | `Remove-VmwareVmSnapshot.ps1` | Change / Write | Medium | No | Built |
| 3 | Provision VM in vSphere | `New-VmwareVirtualMachine.ps1` | Change / Write | Medium | **Yes** | Built |
| 4 | VMware Tools Upgrade | `Update-VmwareTools.ps1` | Change / Write | Medium | **Yes** | Built |
| 5 | VMware Health Check | `Get-VmwareHealthReport.ps1` | Read / Report | Low | No | Built |
| 6 | VM Disk Detail Report | `Get-VmwareVmDiskReport.ps1` | Read / Report | Low | No | Built |
| 7 | VM Power On | `Start-VmwareVirtualMachine.ps1` | Change / Write | Low | No | Built |
| 8 | VM Power Off | `Stop-VmwareVirtualMachine.ps1` | Change / Write | Medium | **Yes** | Built |
| 9 | Reset VM | `Restart-VmwareVirtualMachine.ps1` | Change / Write | Medium | **Yes** | Built |
| 10 | RDM Listing | `Get-VmwareRdmReport.ps1` | Read / Report | Low | No | Built |
| 11 | VM Compute Update | `Set-VmwareVmCompute.ps1` | Change / Write | Medium | **Yes** | Built |
| 12 | vNICs & HBA Driver Info | `Get-VmwareHostAdapterReport.ps1` | Read / Report | Low | No | Built |
| 13 | vSAN Health Info | `Get-VmwareVsanHealth.ps1` | Read / Report | Low | No | Built |

### Safety controls implemented, by row

| # | Guardrail from column L | How it is enforced in code |
|--:|---|---|
| 1 | Additive; datastore-space check in SOP | Datastore free space checked against `-MinimumDatastoreFreePercent` **before** each snapshot; a VM on a tight datastore is skipped and logged. The check is in code, not just the SOP. |
| 2 | Safe with age/name filters; consolidation impact noted | `-MinimumAgeDays` and `-NamePattern` both applied; `-KeepLatest` preserves the newest N. Consolidation IO called out in `.NOTES` and in the per-object log line. |
| 3 | Capacity/cost impact; approve spec | Datastore free-space-after check refuses the provision if it would breach the floor. Duplicate name refused. Cluster CPU/memory headroom included in the approval artifact so the approver sees the capacity impact. VM left powered off. |
| 4 | May require guest reboot; maintenance window | `-NoReboot` passed unless `-AllowReboot` is given, so no guest restarts without a separate decision. VMs with Tools absent are skipped (an upgrade cannot install it). Network-adapter reload warning in `.NOTES`. |
| 5 | Read-only report | Read-only. Reports **HA admission-control headroom** — whether the cluster can still absorb one host failure — not just current usage. |
| 6 | Read-only | Read-only. Thin-provisioned disks flagged separately, since oversubscription is invisible per-VM. |
| 7 | Reversible | Waits for VMware Tools to report running so the result reflects a booted guest. Refuses to run estate-wide without `-VMName` or `-ClusterName`. |
| 8 | Powering off prod VMs needs ticket confirmation; graceful shutdown per SOP | **Graceful guest shutdown first**, always. Hard power-off only as a `-Force` fallback after the timeout, and refused entirely if Tools is absent and `-Force` was not given. Approval-gated. |
| 9 | Hard reset risks data loss; confirm before execution | Guest restart is the default; `-HardReset` must be chosen deliberately and is logged as a warning with the approval and ticket reference. Approval-gated. |
| 10 | Read-only | Read-only. Reports the operational constraint (RDMs block Storage vMotion) alongside each disk. |
| 11 | May require downtime if hot-add disabled; ticket-driven | Reads CPU/memory hot-add settings and reports **up front** whether the change is live or needs a power-off, rather than failing partway. A decrease is always flagged as needing downtime. Will not power a VM off without `-AllowPowerOff`. |
| 12 | Read-only | Read-only. Driver/firmware detail via esxcli; where a host does not expose it the fields are null rather than the adapter being omitted. |
| 13 | Read-only | Read-only. Free-space floor defaults to 25% per vSAN slack-space guidance, and active resync is reported because a rebuilding cluster is less able to survive another failure. |

---

## 01 — AWS (22 of 22)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | AWS Instance Scheduler | `Set-AwsInstanceSchedule.ps1` | Change / Write | Low | No | Built |
| 2 | AWS Limit Monitor | `Get-AwsServiceLimitReport.ps1` | Read / Report | Low | No | Built |
| 3 | Well Architected Review | `Get-AwsWellArchitectedReview.ps1` | Read / Report | Low | No | Built |
| 4 | EC2 Instance Scheduler | `Invoke-AwsEc2ScheduleWindow.ps1` | Change / Write | Low | No | Built |
| 5 | S3 Bucket Public Access Audit | `Get-AwsS3PublicAccessAudit.ps1` | Read / Report | Low | No | Built |
| 6 | IAM Unused Access Key Report | `Get-AwsIamUnusedAccessKeyReport.ps1` | Read / Report | Low | No | Built |
| 7 | Security Hub Findings Aggregation | `Get-AwsSecurityHubFindingSummary.ps1` | Read / Report | Low | No | Built |
| 8 | Cost Explorer Anomaly Alerts | `Get-AwsCostAnomalyReport.ps1` | Read / Report | Low | No | Built |
| 9 | EC2 Patch Compliance (SSM) | `Install-AwsEc2PatchBaseline.ps1` | Change / Write | Medium | **Yes** | Built |
| 10 | RDS Snapshot Automation | `New-AwsRdsSnapshot.ps1` | Change / Write | Low | No | Built |
| 11 | CloudTrail Log Integrity Check | `Test-AwsCloudTrailIntegrity.ps1` | Read / Report | Low | No | Built |
| 12 | Unused EBS Volume Cleanup | `Remove-AwsUnusedEbsVolume.ps1` | **DESTRUCTIVE** | **High** | **Yes** | Built |
| 13 | Auto-Scaling Group Health Check | `Test-AwsAutoScalingGroupHealth.ps1` | Read / Report | Low | No | Built |
| 14 | Config Compliance Dashboard | `Get-AwsConfigComplianceReport.ps1` | Read / Report | Low | No | Built |
| 15 | VPC Flow Log Anomaly Detection | `Get-AwsVpcFlowLogAnomaly.ps1` | Read / Report *(assist-only)* | Low | No | Built |
| 16 | GuardDuty Findings Report | `Get-AwsGuardDutyFindingReport.ps1` | Read / Report | Low | No | Built |
| 17 | Elastic IP Unused Cleanup | `Remove-AwsUnusedElasticIp.ps1` | Change / Write | Medium | **Yes** | Built |
| 18 | Lambda Function Error Rate Monitor | `Get-AwsLambdaErrorRateReport.ps1` | Read / Report | Low | No | Built |
| 19 | EKS Node Health Check | `Set-AwsEksNodeSchedulable.ps1` | Change / Write | Medium | **Yes** | Built |
| 20 | Trusted Advisor Weekly Report | `Get-AwsTrustedAdvisorWeeklyReport.ps1` | Read / Report | Low | No | Built |
| 21 | Route53 Health Check Monitor | `Get-AwsRoute53HealthCheckStatus.ps1` | Read / Report | Low | No | Built |
| 22 | Certificate Expiry Monitor | `Get-AwsCertificateExpiryReport.ps1` | Read / Report | Low | No | Built |

### Safety controls on the non-trivial rows

| # | Guardrail from column L | How it is enforced in code |
|--:|---|---|
| 1, 4 | Scheduled power ops; reversible | Tag-driven. An instance without the schedule tag is never touched. #4 additionally resolves the window in its own **time zone** rather than UTC, and refuses a half-tagged instance instead of guessing one end of the window. |
| 9 | Patching changes servers; agent runs after change-window approval; pre/post snapshot in SOP | Approval-gated. Takes a **pre-patch EBS snapshot of the root volume** by default — that snapshot is the documented rollback. `RebootOption` defaults to `NoReboot`, so a patch run cannot restart a production server on its own. |
| 12 | Deletes volumes >30 days unattached; agent proposes list, human approves deletion | **The library's first Destructive row.** Report-only by default; requires BOTH a valid `-ApprovalReference` AND an explicit `-Execute`. `ConfirmImpact = 'High'`. `-MinimumAgeDays` defaults to 30 exactly as the guardrail states. `-ProtectedList` file and a `DoNotDelete` tag are both unconditional exclusions. **A pre-deletion snapshot is taken and deliberately retained** as the only recovery path. A volume whose detach date cannot be established is skipped — uncertainty never results in a deletion. |
| 15 | Agent runs Athena queries & flags anomalies; separating real threats from noise needs analyst review | **Assist-only** (column H). Runs three Athena queries — rejected-traffic concentrations, top talkers, non-standard ports — and produces a ranked package with an `AnalystNote` on every finding explaining why it might be benign. It **stops there**; the triage judgement is deliberately not scripted. |
| 17 | Releasing EIPs loses the IP permanently; approval gate advised | Approval-gated. Rollback documented as **NONE** — a released EIP returns to the shared AWS pool. Every candidate carries a warning to verify DNS and external allow-lists first, and both a tag-based and an explicit `-ProtectedAddress` exclusion exist. |
| 19 | Auto-cordon of NotReady nodes affects workloads; gate the remediation step | Reporting is free; the **cordon is the gated step**. `-NotReadyMinutes` defaults to 15 so a transient flap is not remediated. Cordon does not evict pods; `-Drain` does and is separately opt-in. Idempotent on an already-cordoned node. |

---

## 02 — Azure (32 of 32)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | Azure VM Stop & Start | `Set-AzVmPowerState.ps1` | Change / Write | Low | No | Built |
| 2 | Azure List of VMs | `Get-AzVmInventory.ps1` | Read / Report | Low | No | Built |
| 3 | Azure Snapshot Creation | `New-AzDiskSnapshot.ps1` | Change / Write | Low | No | Built |
| 4 | Azure Snapshot Deletion | `Remove-AzDiskSnapshot.ps1` | **DESTRUCTIVE** | Medium | **Yes** | Built |
| 5 | Create Resource Groups | `New-AzResourceGroupStandard.ps1` | Change / Write | Low | No | Built |
| 6 | Create VMs | `New-AzVirtualMachine.ps1` | Change / Write | Medium | **Yes** | Built |
| 7 | IT Assist - Password Reset | `Reset-AzEntraUserPassword.ps1` | Change / Write | **High** | **Yes** | Built |
| 8 | IT Assist - Account Lock | `Set-AzEntraUserAccountState.ps1` | Change / Write | **High** | **Yes** | Built |
| 9 | C Drive Cleanup | `Clear-AzVmTempPath.ps1` | Change / Write | Medium | No | Built |
| 10 | AVD Start and Stop Automation | `Set-AzAvdSessionHostPower.ps1` | Change / Write | Low | No | Built |
| 11 | AVD Utilization Report | `Get-AzAvdUtilizationReport.ps1` | Read / Report | Low | No | Built |
| 12 | C Drive Cleanup (Multi-Env) | `Clear-AzVmTempPathMultiEnv.ps1` | Change / Write | Medium | No | Built |
| 13 | Azure Cost Anomaly Detection & Alerts | `Get-AzCostAnomalyReport.ps1` | Read / Report | Low | No | Built |
| 14 | Azure Auto-Scale VM Scale Sets | `Set-AzVmssCapacity.ps1` | Change / Write | Medium | No | Built |
| 15 | Azure NSG Rule Audit & Cleanup | `Remove-AzNsgRule.ps1` | **DESTRUCTIVE** *(assist-only)* | **High** | **Yes** | Built |
| 16 | Azure Disk Unattached Cleanup | `Remove-AzUnattachedDisk.ps1` | **DESTRUCTIVE** | **High** | **Yes** | Built |
| 17 | Azure VM Right-Sizing Report | `Get-AzVmRightSizingReport.ps1` | Read / Report | Low | No | Built |
| 18 | Azure Backup Policy Compliance Report | `Get-AzBackupComplianceReport.ps1` | Read / Report | Low | No | Built |
| 19 | Azure Tag Compliance Enforcement | `Set-AzResourceTagCompliance.ps1` | Change / Write | Low | No | Built |
| 20 | Azure Private Endpoint Provisioning | `New-AzPrivateEndpointConnection.ps1` | Change / Write | Medium | **Yes** | Built |
| 21 | Azure Key Vault Secret Rotation | `Update-AzKeyVaultSecretVersion.ps1` | Change / Write *(assist-only)* | **High** | **Yes** | Built |
| 22 | Azure Resource Lock Management | `Set-AzResourceLock.ps1` | Change / Write | Medium | **Yes** | Built |
| 23 | Azure SQL Database Backup Restore Test | `Test-AzSqlDatabaseRestore.ps1` | Change / Write | Low | No | Built |
| 24 | Azure Firewall Rule Review | `Get-AzFirewallRuleReview.ps1` | Read / Report *(assist-only)* | Low | No | Built |
| 25 | Azure Load Balancer Health Probe Monitor | `Get-AzLoadBalancerHealth.ps1` | Read / Report | Low | No | Built |
| 26 | Azure Entra ID (AAD) Guest User Cleanup | `Remove-AzEntraGuestUser.ps1` | **DESTRUCTIVE** | **High** | **Yes** | Built |
| 27 | Azure Subscription Compliance Dashboard | `Get-AzPolicyComplianceDashboard.ps1` | Read / Report | Low | No | Built |
| 28 | Azure Reserved Instance Utilization Report | `Get-AzReservationUtilization.ps1` | Read / Report | Low | No | Built |
| 29 | Azure VM Patch Compliance Report | `Get-AzVmPatchComplianceReport.ps1` | Read / Report | Low | No | Built |
| 30 | Azure Storage Account Access Review | `Get-AzStorageAccessReview.ps1` | Read / Report | Low | No | Built |
| 31 | Azure DevTest Labs Auto-Shutdown | `Set-AzDevTestLabShutdownSchedule.ps1` | Change / Write | Low | No | Built |
| 32 | Azure Monitor Alert Rule Provisioning | `New-AzMonitorAlertRule.ps1` | Change / Write | Low | No | Built |

> Per-row "how the guardrail is enforced" notes for this category are **not yet written**. The
> gates themselves exist in code — 10 approval-gated rows, 4 Destructive rows with two-phase
> `-Execute`, and the 3 assist-only rows (#15, #21, #24) that stop at a decision package. The
> narrative table is outstanding and is tracked here rather than left silently absent.

---

## 03 — Azure AVD (8 of 8)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | AVD Session Host Drain Mode Toggle | `Set-AvdSessionHostDrainMode.ps1` | Change / Write | Low | No | Built |
| 2 | AVD Image Version Update & Pool Rollout | `Update-AvdHostPoolImage.ps1` | Change / Write *(assist-only)* | **High** | **Yes** | Built |
| 3 | AVD User Session Disconnect & Logoff | `Disconnect-AvdUserSession.ps1` | Change / Write | Medium | **Yes** | Built |
| 4 | AVD Host Pool Scaling Automation | `Set-AvdHostPoolScale.ps1` | Change / Write | Low | No | Built |
| 5 | AVD FSLogix Profile Health Check | `Get-AvdFslogixProfileHealth.ps1` | Read / Report | Low | No | Built |
| 6 | AVD Application Group Assignment | `Add-AvdApplicationGroupAssignment.ps1` | Change / Write | Low | No | Built |
| 7 | AVD Session Host Reimage | `Restore-AvdSessionHost.ps1` | **DESTRUCTIVE** | **High** | **Yes** | Built |
| 8 | AVD Monitoring - Session & Latency Report | `Get-AvdSessionLatencyReport.ps1` | Read / Report | Low | No | Built |

**Overlap with the Azure category, stated deliberately.** `Set-AzAvdSessionHostPower.ps1` (Azure #10)
and `Get-AzAvdUtilizationReport.ps1` (Azure #11) also touch AVD. They are separate workbook rows from
a separate sheet and are built separately, per the rule against merging use cases. The subjects
differ: power state vs. *drain* state, utilisation vs. *session and latency*. Each script's `.NOTES`
points to its counterpart.

### Safety controls implemented, by row

| # | Guardrail from column L | How it is enforced in code |
|--:|---|---|
| 1 | Graceful drain before maintenance; reversible | Fully reversible and disconnects nobody. The real risk with drain mode is the opposite of an outage — it is *silent*: existing sessions continue, so draining the whole pool by mistake goes unnoticed until the next person tries to connect. `-MaxDrainPercent` (default 50) refuses a change that would leave less than half the pool taking connections. |
| 2 | Agent orchestrates image build & staged rollout; **golden image validation / UAT sign-off before rollout is human** | Assist-only and approval-gated. **`-ImageValidated` and `-UatSignOffBy` are both mandatory** — the second records *who*, because "validated" with no name attached is not a sign-off. The image version is resolved in the Compute Gallery **before** the approval is raised, so nobody approves a rollout of an image that may not exist. Rollout runs in batches of `-BatchSize`, and each batch is **drained before it is touched**. The previous image id is logged as the rollback reference. |
| 3 | Force logoff idle >4 hrs can lose unsaved work; **warn users first per SOP** | The warning is the default path and the wait is real: the script sends an on-screen message, sleeps `-WarningMinutes`, then acts. `-SkipWarning` exists for an emergency, **requires `-Reason`**, and logs that the SOP was bypassed. `-DisconnectOnly` is offered and recommended — it frees the connection without ending the session, so nothing is lost, and for most "reclaim idle sessions" goals it is sufficient. Rollback is documented as **none for a logoff**. |
| 4 | Schedule/load-based scaling with **min-host guardrails** | `-MinimumHosts` is checked against the computed target **before** anything is stopped and wins over the schedule. A host with active sessions is **drained, never stopped** — stopping a host with users on it is a disconnection, not a scale-down — and a later run picks it up once empty. Scale-down picks the emptiest hosts first. The wrap-around peak window (e.g. 22:00–05:00) is handled explicitly. |
| 5 | Detect corrupted/oversized VHDx; **report only, repair gated** | Report-only, and the limits are stated rather than implied. It inspects container *files* — size, timestamps, lock state, orphaned differencing disks without a parent. It does **not mount a VHDX**, because mounting a profile container is itself a write against the only copy of a user's desktop, and doing that on a schedule to look for problems is how you cause them. A container held open by a live session is normal; the report distinguishes that from one held open and unwritten for weeks. |
| 6 | ITSM-driven RemoteApp group assignment; **the ticket is the approval** | Not approval-gated, because the workbook says the ticket *is* the approval — so `-TicketReference` is **mandatory** here rather than optional as it is elsewhere in the library. Idempotent against existing role assignments. Each user-level assignment carries advice to assign an Entra group instead, which moves the decision to group membership where the Access Review campaigns (Security Cloud #11) can see it. |
| 7 | Reimage wipes host state; **drain + approval before trigger** | Destructive, and both halves are verified rather than trusted. A host **not already in drain mode is EXCLUDED** — the script will not drain and reimage in one run, because that gives sessions no time to end. A host with active sessions is excluded unless `-AllowActiveSessions` is passed, which cuts those users off with no warning. Report-only + `-Execute` + approval on top. What is lost is stated precisely: with FSLogix the profile lives on the share and survives; anything on the local disk does not. The host is left in drain mode afterwards, deliberately. |

---

## 04 — OCI (15 of 15)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | OCI Instance Start/Stop/Reboot | `Set-OciInstancePowerState.ps1` | Change / Write | Low | No | Built |
| 2 | OCI Instance Provisioning | `New-OciInstance.ps1` | Change / Write | Medium | **Yes** | Built |
| 3 | OCI Block Volume Backup | `New-OciBlockVolumeBackup.ps1` | Change / Write | Low | No | Built |
| 4 | OCI Boot Volume Snapshot | `New-OciBootVolumeBackup.ps1` | Change / Write | Low | No | Built |
| 5 | OCI Cost & Budget Alert | `Get-OciBudgetAlert.ps1` | Read / Report | Low | No | Built |
| 6 | OCI Compartment Resource Inventory | `Get-OciCompartmentInventory.ps1` | Read / Report | Low | No | Built |
| 7 | OCI Tag Compliance Enforcement | `Set-OciResourceTagCompliance.ps1` | Change / Write | Low | No | Built |
| 8 | OCI IAM User & Group Audit | `Get-OciIamAudit.ps1` | Read / Report | Low | No | Built |
| 9 | OCI Security List / NSG Rule Review | `Get-OciNetworkRuleReview.ps1` | Read / Report | Low | No | Built |
| 10 | OCI Autonomous DB Start/Stop | `Set-OciAutonomousDbState.ps1` | Change / Write | Low | No | Built |
| 11 | OCI Load Balancer Health Check | `Get-OciLoadBalancerHealth.ps1` | Read / Report | Low | No | Built |
| 12 | OCI Patch Management (OS Mgmt Service) | `Install-OciPatchUpdate.ps1` | Change / Write | Medium | **Yes** | Built |
| 13 | OCI Object Storage Lifecycle Policy | `Set-OciObjectLifecyclePolicy.ps1` | **DESTRUCTIVE** | Medium | **Yes** | Built |
| 14 | OCI VCN Flow Log Analysis | `Get-OciVcnFlowLogAnomaly.ps1` | Read / Report *(assist-only)* | Low | No | Built |
| 15 | OCI DR Failover Test | `Invoke-OciDrPlanExecution.ps1` | **DESTRUCTIVE** *(assist-only)* | **High** | **Yes** | Built |

### Safety controls implemented, by row

| # | Guardrail from column L | How it is enforced in code |
|--:|---|---|
| 1 | Controlled power ops with audit logging | Selection must be explicit — `-InstanceName`, `-InstanceId` or `-TagKey`+`-TagValue`. The script will not act on a whole compartment, and `-TagKey` without `-TagValue` is refused as too broad for a power operation. Instances already in the target state are skipped rather than re-issued. The hard/soft distinction is surfaced rather than buried: `STOP` and `RESET` pull the power, `SOFTSTOP`/`SOFTRESET` ask the guest, and a hard operation says so in the success log. |
| 2 | **Cost impact; approve shape/image before deploy** | The change set names exactly what the guardrail asks an approver to look at — shape, OCPU, memory, image and OS. The image and shape are validated against the compartment *before* the approval is raised, so nobody approves a launch that cannot happen. **No cost figure is computed.** OCI pricing depends on the tenancy agreement and no API here would make such a number true; an invented estimate on an approval artifact would be worse than none, so the row says "Cost NOT calculated — price the shape against your own rate card". |
| 12 | Scheduled OS patching; **change-window approval + pre-snapshot** | Approval-gated, and the pre-snapshot is mandatory by construction: a FULL boot volume backup is taken and waited on **before** the patch call, and an instance whose boot volume cannot be resolved is **excluded entirely** rather than patched without a rollback point. `-SkipPreSnapshot` exists but logs a WARN stating it contradicts the guardrail. Which OS Management service applies (Hub vs legacy) is a parameter, not a guess. |
| 13 | Auto-tier/delete by age; **deletion rules reviewed before enabling** | Destructive *on a delay*, which is what makes it unusual. Applying a lifecycle DELETE rule destroys nothing at that moment — it destroys objects continuously from then on, without further approval, as they age past the threshold. So the gate is on the rule set, not on a delete call: any file containing a DELETE rule is **refused** until `-DeletionRulesReviewed` is passed, and the change set states the standing effect in those words. The previous policy is logged before being replaced, as the rollback. The rule array is normalised and re-serialised so what is applied is exactly what was approved, whatever shape the source file had. |
| 14 | Agent surfaces anomalies; **interpretation & incident declaration need analyst judgment** | Assist-only. Three queries — rejected-traffic concentrations, top talkers, unusual ports — each finding carrying an `AnalystNote` giving the **benign** explanation, because a ranked list with no counter-argument reads as a list of incidents. Truncation at `-MaxResults` is logged as making the ranking unreliable. An empty result is flagged as ambiguous: no traffic and no flow logging look identical to this query, and they are very different situations. |
| 15 | Agent executes runbook steps & collects evidence; **go/no-go decision and results assessment are human (DR drill governance)** | Assist-only, Destructive, approval-gated. The mechanical half is fully automated — executing the plan and writing a per-step evidence pack — because a drill run by hand produces worse evidence than one run by script. Neither judgement is automated: `-GoDecisionBy` is **mandatory** and records who authorised the drill, and the evidence pack carries an explicit note that PASS/FAIL is a drill-review decision deliberately absent from it. The plan **type is read before execution** and a `FAILOVER` plan is refused without `-FailoverAuthorized` — the difference between a drill and moving production is one plan selection. |

### Notes on the remaining rows

- **#7 tag compliance** carries an explicit map of the resource types it can write (instance, block
  volume, boot volume, VCN, subnet, bucket) because OCI has no single tag-update call. Anything else
  is **reported as non-compliant and marked as having no updater** — silently treating it as
  compliant would be the easy wrong answer. Existing tags are merged rather than replaced, since
  `--freeform-tags` overwrites the whole map.
- **#9 rule review** ranks by what a rule actually exposes: `ALL` protocol or unrestricted ports is
  Critical, an administrative port is High, anything else open is Review. It changes nothing — whether
  0.0.0.0/0 on 443 is correct depends on what is behind it.
- **#10 Autonomous DB** is tag-driven by default (`schedule=dev`), so a production database without
  the tag is never a candidate. Stopping terminates connected sessions, which is stated on every row.
- **#5 budgets** flags a budget with **no alert rule** as a finding: it tracks spend and tells nobody.
  Spend figures are read from OCI, never recalculated.
- **#8 IAM audit** does not assert that a federated user lacks MFA — it reports that OCI has no record
  of one, which is not the same thing when MFA lives in the IdP.
- **#11 load balancer** parses the certificate PEM to get real expiry dates, and notes that a backend
  passing its health check says nothing about whether the application is returning correct answers.

### Platform note

Oracle ships no first-party OCI PowerShell module, so all fifteen scripts wrap the `oci` CLI and
parse its JSON. A shared prologue is compiled into each:

- **The CLI is resolved and verified before anything else** — a missing `oci` fails with an
  instruction, not a cryptic command-not-found.
- **The profile parameter is `-CliProfile`, not `-Profile`**, because `$Profile` is a PowerShell
  automatic variable holding the profile script path.
- **`$ErrorActionPreference` is relaxed to `Continue` for the duration of each CLI call and restored
  afterwards.** Windows PowerShell turns redirected native stderr into terminating errors under
  `Stop` even when the process exits 0; the exit code is the signal that actually matters.
- **Credentials never appear.** Authentication comes entirely from the CLI config profile; API keys
  live in `~/.oci` and no OCI secret is read from `config.json`.

---

## 05 — M365 (22 of 22)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | Teams Channel Auto-Provisioning | `New-TeamsChannel.ps1` | Change / Write | Low | No | Built |
| 2 | Teams Inactive Channels Cleanup | `Remove-TeamsInactiveChannel.ps1` | **DESTRUCTIVE** | Medium | **Yes** | Built |
| 3 | SharePoint Site Provisioning | `New-SharePointSite.ps1` | Change / Write | Low | No | Built |
| 4 | SharePoint Storage Quota Report | `Get-SharePointStorageReport.ps1` | Read / Report | Low | No | Built |
| 5 | OneDrive External Sharing Audit | `Get-OneDriveExternalSharing.ps1` | Read / Report | Low | No | Built |
| 6 | Intune Device Compliance Report | `Get-IntuneDeviceCompliance.ps1` | Read / Report | Low | No | Built |
| 7 | Intune App Deployment Automation | `Add-IntuneAppAssignment.ps1` | Change / Write | Medium | **Yes** | Built |
| 8 | Intune Device Retire/Wipe | `Clear-IntuneManagedDevice.ps1` | **DESTRUCTIVE** | **High** | **Yes** | Built |
| 9 | M365 License Optimization Report | `Get-M365LicenseOptimization.ps1` | Read / Report | Low | No | Built |
| 10 | Entra ID Conditional Access Policy Audit | `Get-EntraConditionalAccessAudit.ps1` | Read / Report | Low | No | Built |
| 11 | Entra ID PIM Role Activation Report | `Get-EntraPimActivationReport.ps1` | Read / Report | Low | No | Built |
| 12 | M365 Secure Score Monitoring | `Get-M365SecureScore.ps1` | Read / Report | Low | No | Built |
| 13 | Teams Meeting Recording Cleanup | `Remove-TeamsMeetingRecording.ps1` | **DESTRUCTIVE** | Medium | **Yes** | Built |
| 14 | Planner Task Auto-Assignment | `New-PlannerTask.ps1` | Change / Write | Low | No | Built |
| 15 | M365 Admin Audit Log Export | `Export-M365AuditLog.ps1` | Read / Report | Low | No | Built |
| 16 | Exchange Online Anti-Spam Policy Review | `Set-ExoAntiSpamPolicyBaseline.ps1` | Change / Write *(assist-only)* | Medium | **Yes** | Built |
| 17 | M365 Data Loss Prevention Policy Report | `Get-M365DlpMatchReport.ps1` | Read / Report | Low | No | Built |
| 18 | Entra ID Sign-In Risk Report | `Get-EntraRiskySignInReport.ps1` | Read / Report | Low | No | Built |
| 19 | M365 Email Threat Report (Defender) | `Get-M365EmailThreatReport.ps1` | Read / Report | Low | No | Built |
| 20 | M365 Retention Policy Compliance Check | `Get-M365RetentionCompliance.ps1` | Read / Report | Low | No | Built |
| 21 | Viva Insights Usage Report | `Get-VivaInsightsUsageReport.ps1` | Read / Report | Low | No | Built |
| 22 | Power Platform Connector Governance | `Get-PowerPlatformConnectorAudit.ps1` | Read / Report | Low | No | Built |

### Safety controls implemented, by row

| # | Guardrail from column L | How it is enforced in code |
|--:|---|---|
| 2 | Archive/delete >90-day channels; **archive first, delete only after owner confirmation** | Two modes. `-Mode Archive` is the default and is what the guardrail asks for. `-Mode Delete` additionally requires `-OwnerConfirmed`, which the script refuses to proceed without — so "delete" cannot be reached by escalating a single flag. Activity is measured from the last message in the channel, and a channel whose message history cannot be read is **skipped rather than assumed inactive**. The General channel of any team is excluded unconditionally; Teams itself does not permit its deletion, and treating that as a runtime error rather than a filter would abort the batch. |
| 7 | Pushing apps to device groups; **approve app + target group** | Approval-gated. The change set names both halves the guardrail asks to approve — the app and the resolved target group — and records the group's **member count**, so an approver sees the blast radius rather than a group name. `Required` intent is called out as installing silently at next check-in, distinct from `Available`, which only offers the app in Company Portal. Re-running against an existing assignment with the same intent is a logged no-op. |
| 8 | Wipe is destructive; **execute only from verified ITSM trigger with approval** | The library's most destructive M365 row. Report-only by default, plus `-Execute`, plus a valid `-ApprovalReference`. Action defaults to **Retire** (removes company data, leaves personal data); `-Action Wipe` additionally requires `-ItsmTriggerVerified`, which is the operator asserting the "verified ITSM trigger" the guardrail names. `ConfirmImpact = 'High'`. Rollback is documented as **none** — a wiped device is re-enrolled, not restored. |
| 13 | Deleting recordings >30 days; **confirm retention/legal-hold exclusions in SOP** | Report-only + `-Execute` + approval. `-MinimumAgeDays` defaults to 30, matching the guardrail. Each candidate is checked for an **item-level retention label** and excluded if one is present. Tenant-level eDiscovery holds are *not* visible to this API, so the script refuses to run at all without `-LegalHoldConfirmed` — the operator asserting the SOP check was done. That limitation is stated in `.NOTES` rather than papered over. |
| 16 | Agent reports current policy vs baseline; **deciding how far to tighten (mail-flow business impact) is messaging admin judgment** | Assist-only **and** approval-gated, so it reports and then stops at the gate rather than acting. It compares each policy against a baseline (built-in, or `-BaselineFile`) and emits one row per deviation with an `AdminDecision` column stating the trade-off. It applies nothing until a reference is approved, and `-ApplySetting` lets an admin approve the review then apply **only part** of it — the judgement stays with the human at the granularity the guardrail describes. Each change logs the previous value, which is the documented rollback. |

### Notes on the read-only rows

- **#12 Secure Score** compares against the previous run stored on disk. The finding that matters is a
  *drop*, not the absolute number, so a fall of `-DropAlertPoints` or more is logged at WARN.
- **#15 Audit log export** pages explicitly through `Search-UnifiedAuditLog`. A single call returns
  one bounded page and silently loses the rest. It also states in `.NOTES` that unified audit
  ingestion lags up to 24h — overlap windows and de-duplicate downstream — and logs a WARN when the
  `-MaxRecords` ceiling truncates the export.
- **#18 Risky sign-ins** separates risky sign-ins that **succeeded** from those blocked; only the
  former is a finding. Where the tenant lacks Entra ID P2 the endpoint returns nothing, which the
  script reports as **missing licensing rather than a clean result**.
- **#19 Defender threats** likewise separates *delivered* from *blocked*.
- **#20 Retention** flags policies that are disabled, in simulation mode, scoped to nothing, or have
  no rules attached — all of which look configured while retaining nothing.
- **#21 Usage** detects and reports when tenant reports are **pseudonymised** by the M365 admin-centre
  privacy setting, rather than presenting opaque identifiers as user names.

---

## 12 — Exchange & O365 (25 of 25)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | Exchange Health Checks | `Get-ExoHealthReport.ps1` | Read / Report | Low | No | Built |
| 2 | O365 Health Check | `Get-O365ServiceHealth.ps1` | Read / Report | Low | No | Built |
| 3 | Full Access Addition on Mailbox | `Add-ExoMailboxFullAccess.ps1` | Change / Write | **High** | **Yes** | Built |
| 4 | Mailbox Access Removal | `Remove-ExoMailboxFullAccess.ps1` | Change / Write | Low | No | Built |
| 5 | Check Permissions on Mailbox | `Get-ExoMailboxPermission.ps1` | Read / Report | Low | No | Built |
| 6 | Provisioning 'On Behalf Of' Permissions | `Add-ExoSendOnBehalf.ps1` | Change / Write | Medium | **Yes** | Built |
| 7 | Removal of 'On Behalf Of' Permissions | `Remove-ExoSendOnBehalf.ps1` | Change / Write | Low | No | Built |
| 8 | Check 'On Behalf Of' Permissions | `Get-ExoSendOnBehalf.ps1` | Read / Report | Low | No | Built |
| 9 | Explicit Folder Permission Addition | `Add-ExoFolderPermission.ps1` | Change / Write | Medium | **Yes** | Built |
| 10 | Removal of Explicit Folder Permission | `Remove-ExoFolderPermission.ps1` | Change / Write | Low | No | Built |
| 11 | Explicit Folder Permission Check | `Get-ExoFolderPermission.ps1` | Read / Report | Low | No | Built |
| 12 | Provisioning 'Send As' Permissions | `Add-ExoSendAsPermission.ps1` | Change / Write | **High** | **Yes** | Built |
| 13 | Removing 'Send As' Permissions | `Remove-ExoSendAsPermission.ps1` | Change / Write | Low | No | Built |
| 14 | Check 'Send As' Permissions | `Get-ExoSendAsPermission.ps1` | Read / Report | Low | No | Built |
| 15 | Email Migration (On-Prem to Cloud) | `Move-ExoMailboxToCloud.ps1` | **DESTRUCTIVE** *(assist-only)* | **High** | **Yes** | Built |
| 16 | O365 License Assignment (Add/Delete) | `Set-O365UserLicense.ps1` | Change / Write | Medium | **Yes** | Built |
| 17 | Add/Remove Mailbox Delegation | `Set-ExoMailboxDelegation.ps1` | Change / Write | Medium | **Yes** | Built |
| 18 | Email Group Creation | `New-ExoDistributionGroup.ps1` | Change / Write | Low | No | Built |
| 19 | Shared Mailbox Conversion | `Convert-ExoSharedMailbox.ps1` | Change / Write | Medium | **Yes** | Built |
| 20 | Add User into O365 Group | `Add-O365GroupMember.ps1` | Change / Write | Medium | **Yes** | Built |
| 21 | Email Forwarding | `Set-ExoMailboxForwarding.ps1` | Change / Write | **High** | **Yes** | Built |
| 22 | Add/Remove Email Alias | `Set-ExoMailboxAlias.ps1` | Change / Write | Low | No | Built |
| 23 | Enable/Disable MFA | `Set-EntraUserMfaState.ps1` | Change / Write | **High** | **Yes** | Built |
| 24 | Reset MFA | `Reset-EntraUserMfaMethod.ps1` | Change / Write | **High** | **Yes** | Built |
| 25 | Block/Unblock Mobile Devices | `Set-ExoMobileDeviceAccess.ps1` | Change / Write | Medium | **Yes** | Built |

> Per-row enforcement notes for this category are **not yet written**. 13 rows are approval-gated
> in code, including every identity-sensitive one (#21 forwarding as a data-exfil vector, #23/#24
> MFA). The narrative table is outstanding.

---

## 13 — AD & Identity (12 of 12)

| # | Use case | Script | Type | Risk | Approval | Status |
|--:|---|---|---|---|---|---|
| 1 | User Onboarding - mailbox in O365 | `New-AdUserOnboarding.ps1` | Change / Write | Medium | No | Built |
| 2 | User Onboarding - mailbox in Exchange | `New-AdUserOnboardingOnPrem.ps1` | Change / Write | Medium | No | Built |
| 3 | User Offboarding - mailbox in O365 | `Remove-AdUserOffboardingCloud.ps1` | **DESTRUCTIVE** | **High** | **Yes** | Built |
| 4 | User Offboarding - mailbox in Exchange | `Remove-AdUserOffboardingOnPrem.ps1` | **DESTRUCTIVE** | **High** | **Yes** | Built |
| 5 | Offboarding sub-tasks (Disable, move OU, manager removal) | `Invoke-AdOffboardingTask.ps1` | Change / Write | **High** | **Yes** | Built |
| 6 | Share Folder Creation & Access Modification | `Set-AdShareFolderAccess.ps1` | Change / Write | Medium | **Yes** | Built |
| 7 | Reset Password / Unlock Account | `Reset-AdUserPassword.ps1` | Change / Write | **High** | **Yes** | Built |
| 8 | Account Modification | `Set-AdUserAttribute.ps1` | Change / Write | Medium | **Yes** | Built |
| 9 | Set Account Expiry | `Set-AdAccountExpiry.ps1` | Change / Write | Low | No | Built |
| 10 | Active Directory Health Check | `Get-AdHealthReport.ps1` | Read / Report | Low | No | Built |
| 11 | Identify Hostname & IP Address | `Get-AdComputerAddress.ps1` | Read / Report | Low | No | Built |
| 12 | Create Organisation Unit | `New-AdOrganizationalUnit.ps1` | Change / Write | Low | No | Built |

> Per-row enforcement notes for this category are **not yet written**. Both offboarding rows are
> Destructive with two-phase `-Execute` plus an approval gate; the password reset builds its
> `SecureString` character by character rather than round-tripping a plaintext string. The
> narrative table is outstanding.

---

## Needs Input

Items where environment-specific detail is required and was **not invented**. Each is exposed as a
parameter or config key with a clearly marked `REPLACE-ME` placeholder.

| Item | Where | Needed for |
|---|---|---|
| SMTP relay, from-address, recipients | `Config/config.json` – `notifications` | `-SendReport` on any reporting script |
| Teams webhook URL | `Config/config.json` – `notifications.teamsWebhookUrl` | Teams delivery channel |
| ITSM create-ticket URL, category, assignment group | `Config/config.json` – `itsm` | Raising tickets from approval requests |
| Protected computer list | `Config/config.json` – `safety.protectedComputers` | Reboot exclusions — **currently a placeholder; populate before first use** |
| Maintenance window hours | `Config/config.json` – `maintenance` | Reboot window enforcement (defaults 22:00—05:00) |
| Restartable service whitelist | `Config/config.json` – `safety.restartableServices` | Service restart — shipped with 4 common entries; extend per your SOP |
| AWS region / profile | Script parameters `-Region`, `-ProfileName` | Every AWS script. Prefer an IAM role over a profile. |
| Hyper-V virtual switch names | Script parameter `-SwitchName` | VM provisioning and NIC changes |
| Live migration delegation | Host configuration, not a script parameter | `Move-HvVirtualMachine.ps1` needs Kerberos constrained delegation or CredSSP between hosts |
| vCenter server | `Config/config.json` – `vmware.vCenterServer` | Every VMware script, unless `-VIServer` is passed |
| vSphere cluster / datastore / portgroup names | Script parameters | VM provisioning and compute resize |
| Athena database, flow log table, S3 results bucket | Script parameters on `Get-AwsVpcFlowLogAnomaly.ps1` | VPC flow log analysis. Partition the table by date — an unpartitioned scan is expensive. |
| kubectl and AWS CLI on PATH | Host prerequisite | `Set-AwsEksNodeSchedulable.ps1` |
| Entra app registration + certificate thumbprint | `Config/config.json` – `azure` | App-only auth for every Exchange Online and Security & Compliance script. Certificate auth only — no client secret is read from config. |
| Anti-spam baseline | `-BaselineFile` on `Set-ExoAntiSpamPolicyBaseline.ps1` | The built-in baseline is a **conservative starting point for a conversation, not a target**. Replace it with your own before applying anything. |
| Approved Power Platform connector list | `-ApprovedConnector` on `Get-PowerPlatformConnectorAudit.ps1` | Ships with 8 first-party connectors. Everything else is flagged, so an unedited list will be noisy in a tenant with sanctioned third-party connectors. |
| Secure Score state file | `-StateFile` on `Get-M365SecureScore.ps1` | Defaults to `%ProgramData%\ITAutomation\State`. The first run has nothing to compare against and reports "first run" rather than a fabricated delta. |
| Entra ID P2 licensing | Tenant prerequisite | `Get-EntraRiskySignInReport.ps1` and `Get-EntraPimActivationReport.ps1`. Without P2 the endpoints return nothing; the script says so rather than reporting a clean result. |
| Power Platform administrator role | Tenant prerequisite | `Get-PowerPlatformConnectorAudit.ps1` — the admin API is separate from Graph and Graph permissions alone are not enough. |
| Commvault web service URL | `Config/config.json` – `commvault.webServiceUrl` | Every Commvault script, unless `-WebServiceUrl` is passed. |
| **Tape export endpoint path** | `-ExportApiPath` on `Export-CvTapeMedia.ps1` | **PLACEHOLDER.** Default `Library/{0}/Media/{1}/action/export`. This path differs between Commvault versions — verify it against your CommCell REST reference before the first run. It was parameterised rather than guessed at silently. |
| **Restore submission endpoint** | `-RestoreApiPath` on `Restore-CvBackupData.ps1` | **PLACEHOLDER.** Default `CreateTask`. Verify against your CommCell version; the restore task body shape also varies. |
| Desired-state file for subclients | `-DesiredStateFile` on `Set-CvSubclientConfiguration.ps1` | Mandatory. There is no built-in baseline — a shipped default for what a subclient *should* look like would be exactly the protection-design decision the guardrail reserves for a human. |
| Backup window hours | `-WindowStartHour` / `-WindowEndHour` on `Restart-CvFailedJob.ps1` | Defaults 22:00—05:00, matching `maintenance` in config. Set to your actual window before scheduling. |
| OCI CLI on PATH | Host prerequisite | Every OCI script. There is no first-party OCI PowerShell module; these wrap the `oci` CLI and fail with an instruction if it is absent. |
| OCI profile, region, compartment, tenancy | `Config/config.json` → `oci` | Every OCI script, unless passed as parameters. API keys stay in `~/.oci/config` and are never read from here. |
| **DR service CLI command group** | `-DrCliGroup` on `Invoke-OciDrPlanExecution.ps1` | **PLACEHOLDER.** Default `disaster-recovery`. Verify against your CLI version. |
| OS Management service flavour | `-OsManagementService` on `Install-OciPatchUpdate.ps1` | OCI has both OS Management Hub and the legacy OS Management service, with different CLI command groups. Defaults to `os-management-hub`. Set it once for your tenancy. |
| Object Storage lifecycle rules file | `-RulesFile` on `Set-OciObjectLifecyclePolicy.ps1` | Mandatory. No default rule set ships — a shipped default that deletes objects by age would be the opposite of the guardrail on that row. |
| VCN flow log group OCID | `-LogGroupId` on `Get-OciVcnFlowLogAnomaly.ps1` | Mandatory. Flow logging must be enabled on the subnets of interest; the script cannot distinguish "no traffic" from "no logging". |
| `Posh-SSH` module | Host prerequisite | Every Network Devices script. |
| Device credential | `-Credential` (prompted) or `-KeyFile` | Every Network Devices script. **No device password is read from configuration and none appears in any script.** |
| Command sets for unlisted vendors | `-Vendor generic -Command '...'` | Built-in command sets exist for `cisco-ios`, `cisco-nxos`, `arista-eos` and `juniper-junos`. Any other platform must supply its own commands — they are never guessed at. |
| Standard NTP server list | `-NtpServer` on `Set-NetDeviceNtp.ps1` | Mandatory. This is the SOP standard the fleet is compared against; there is no shipped default. |
| Junos access-VLAN syntax | `Set-NetInterfaceVlan.ps1` | **Not implemented.** Junos switching syntax differs enough from the IOS-style platforms that it is not assumed; the script throws for `juniper-junos` rather than sending a command that might mean something else. |
| Scanner API base URL | `Config/config.json` → `vulnerability.apiBaseUrl` | `Start-VulnerabilityScan.ps1`. Scanner API keys are **never** stored here — they are SecureString parameters at run time. |
| **Qualys endpoint paths** | `Start-VulnerabilityScan.ps1` | Qualys launch/status paths differ between deployments. Tenable.io is the implemented path; Qualys is best-effort and should be verified against your subscription. |
| Phishing known-pattern file | `-KnownPatternFile` on `Invoke-SentinelPhishingTriage.ps1` | **Mandatory, no default.** Without it nothing is high-confidence and nothing would be eligible for automatic closure — which is the correct failure mode, not a gap. |
| Dependency inventory | `-DependencyInventoryFile` on `Update-ServiceAccountSecret.ps1` | **Mandatory.** Lists which systems consume each application's secret. This is the human dependency-discovery step the guardrail requires; an application absent from it is never rotated. |
| HIBP API key | `-ApiKey` (SecureString) on `Get-BreachCredentialAlert.ps1` | A **paid** key is required. Domain search additionally needs the domain verified in your HIBP account. |
| Sentinel workspace + resource group | Parameters on `Invoke-SentinelPhishingTriage.ps1`, `Get-SiemLogSourceHealth.ps1`, `Get-DataExfiltrationAlert.ps1` | Mandatory on each. |
| AWS Config conformance pack name | `-ConformancePackName` on `Get-CisBenchmarkCompliance.ps1` | Required to query AWS for CIS; there is no default pack name. |
| Appliance firewall change logs | `Get-FirewallRuleChangeAudit.ps1` | **Not covered.** Azure Activity Log and AWS CloudTrail are implemented. Palo Alto and other appliance firewalls keep their change logs on the appliance and need their own credentials. |
| WAF providers other than Azure Front Door | `Update-CloudWafRuleSet.ps1` | **Not implemented.** AWS WAF and OCI WAF have different managed-rule models; only Azure Front Door is built. |
| **AVD session host configuration api-version** | `-ApiVersion` on `Update-AvdHostPoolImage.ps1` | **PLACEHOLDER.** Default `2024-04-08-preview`. The session host configuration and update APIs moved through several preview versions — verify against your tenant before the first rollout. |
| AVD scale set name | `-VmssName` on `Restore-AvdSessionHost.ps1` | Reimage is a scale set operation. A host pool built from standalone VMs is replaced by redeployment, which this script deliberately does not do — those hosts are reported as excluded. |
| FSLogix profile share path | `-ProfileSharePath` on `Get-AvdFslogixProfileHealth.ps1` | Mandatory. Read access only; the script never requests write access to the profile share. |
| AVD diagnostic settings | Workspace prerequisite | `Get-AvdSessionLatencyReport.ps1` needs `WVDConnections`, `WVDConnectionNetworkData` and `WVDErrors` flowing to the workspace. A missing table is reported as **NOT COLLECTED**, not as no problems. |

---

## Workbook data notes

Observations recorded during the read, not corrections applied to the workbook:

1. **Column F has four values, not the two the prompt assumes.** `Yes` (168), `Partial` (37),
   `Yes - with Human Approval` (6), `Need to check` (2).
2. **Column H has three values.** `Yes` (140), `Yes - With Approval` (52), `Partially - Agent Assists` (21).
   `Yes - With Approval` is treated as equivalent to a column-K approval gate.
3. **2 rows are marked `Need to check`** — unresolved feasibility, not a build instruction. Both are
   in the Azure sheet and both are identity-sensitive:

   | Sheet | # | Use case | Script built | Note |
   |---|--:|---|---|---|
   | Azure | 7 | IT Assist - Password Reset | `Reset-AzEntraUserPassword.ps1` | Built and approval-gated. The workbook's uncertainty is about *feasibility of the assist*, not the mechanics — resetting a password is trivial; verifying the requester is who they claim is the part nobody has settled. The script requires an `-ApprovalReference` and a `-TicketReference` and does not attempt identity verification itself. |
   | Azure | 8 | IT Assist - Account Lock | `Set-AzEntraUserAccountState.ps1` | As above. Built, approval-gated, ticket-driven. |

   Both were built rather than skipped, because the mechanics are unambiguous and the guardrail
   (verify the requester out-of-band before acting) is enforceable as a gate. **The open question
   the workbook is flagging is a process one and is not resolved by this library** — it needs a
   decision about how a service desk establishes caller identity.
4. **All 213 rows have Remarks/Guardrails populated**, so no script will ship with an empty guardrail note.
5. **All 16 Destructive rows are also approval-gated**, so each will carry both two-phase `-Execute`
   behaviour and an `-ApprovalReference` gate.

---

## Validation performed

| Check | Result |
|---|---|
| `Invoke-ScriptAnalyzer -Severity Error,Warning` on Scripts, Modules, Tests | **0 findings** |
| PowerShell AST parse of all 213 scripts | **213/213 OK** |
| `Invoke-Pester -Path .\Tests` | **24 passed, 0 failed** |
| Approval gate refuses Pending / expired / wrong-script / missing references | Proven by test |
| Secrets redacted from logs and approval artifacts | Proven by test |

**Not yet performed:** no script has been executed against a real server, tenant, appliance or
scanner. All validation to date is static analysis plus module-level unit tests with mocked inputs.
Every category SOP repeats this in its own "Known limitations" section, because it is the single most
important thing to know before running any of this.

---

## Library composition

Counted from the workbook, not estimated.

| | Count |
|---|--:|
| Total use cases | **213** |
| Read / Report | 96 |
| Change / Write | 101 |
| Destructive / High-Impact | 16 |
| Approval-gated (column K = Yes) | **66** |
| Agent-assist (column H) | **21** |

**All 16 Destructive rows carry both** two-phase `-Execute` behaviour **and** an `-ApprovalReference`
gate, as predicted when the workbook was first read.

### The 16 Destructive rows

| Sheet | # | Use case | Script |
|---|--:|---|---|
| AWS | 12 | Unused EBS Volume Cleanup | `Remove-AwsUnusedEbsVolume.ps1` |
| Azure | 4 | Snapshot Deletion | `Remove-AzDiskSnapshot.ps1` |
| Azure | 15 | NSG Rule Audit & Cleanup | `Remove-AzNsgRule.ps1` |
| Azure | 16 | Disk Unattached Cleanup | `Remove-AzUnattachedDisk.ps1` |
| Azure | 26 | Entra ID Guest User Cleanup | `Remove-AzEntraGuestUser.ps1` |
| Azure AVD | 7 | Session Host Reimage | `Restore-AvdSessionHost.ps1` |
| OCI | 13 | Object Storage Lifecycle Policy | `Set-OciObjectLifecyclePolicy.ps1` |
| OCI | 15 | DR Failover Test | `Invoke-OciDrPlanExecution.ps1` |
| M365 | 2 | Teams Inactive Channels Cleanup | `Remove-TeamsInactiveChannel.ps1` |
| M365 | 8 | Intune Device Retire/Wipe | `Clear-IntuneManagedDevice.ps1` |
| M365 | 13 | Teams Meeting Recording Cleanup | `Remove-TeamsMeetingRecording.ps1` |
| Network Devices | 8 | Enable/Disable Interface Ports | `Set-NetInterfaceState.ps1` |
| Backup Commvault | 9 | Backup Restoration | `Restore-CvBackupData.ps1` |
| Exchange & O365 | 15 | Email Migration (On-Prem to Cloud) | `Move-ExoMailboxToCloud.ps1` |
| AD & Identity | 3 | User Offboarding (O365 mailbox) | `Remove-AdUserOffboardingCloud.ps1` |
| AD & Identity | 4 | User Offboarding (Exchange mailbox) | `Remove-AdUserOffboardingOnPrem.ps1` |

---

## Documentation

| Document | Covers |
|---|---|
| `Docs/SOP-WindowsServer.md` | 11 — Windows Server |
| `Docs/SOP-AzureAVD.md` | 03 — Azure AVD |
| `Docs/SOP-OCI.md` | 04 — OCI |
| `Docs/SOP-M365.md` | 05 — M365 |
| `Docs/SOP-SecurityCloud.md` | 06 — Security Cloud |
| `Docs/SOP-NetworkDevices.md` | 07 — Network Devices |
| `Docs/SOP-BackupCommvault.md` | 08 — Backup Commvault |

**Outstanding documentation**, recorded rather than left silently absent:

- SOPs for AWS, Azure, Hyper-V, VMware OnPrem, Exchange & O365 and AD & Identity.
- Per-row "how the guardrail is enforced" narrative tables for Azure, Exchange & O365 and
  AD & Identity — their script tables are present above; the enforcement prose is not.

