# SOP — Cloud Security Automation

Standard operating procedure for the eighteen scripts in `Scripts/06-SecurityCloud`.

**Source:** `Agent_Automation_Feasibility_Assessment.xlsx`, sheet *Security Cloud*, use cases #1–#18.

---

## 1. The shape of this category

Every row on this sheet is marked feasibility **Partial**, and **eight of eighteen** are agent-assist
— the highest proportion in the library. That is not a limitation of the tooling. It is what security
work is: the gathering, enrichment and correlation are mechanical and worth automating; the judgement
is not, and automating it anyway produces confident wrong answers at machine speed.

These scripts are written to stop where the workbook says a human decides. Three things follow from
that, and they are worth knowing before you run anything:

- **Some scripts deliberately refuse to act** even when they have everything needed to. #2 will not
  block a sender. #10 will not isolate a device on a severity threshold. #3 will not touch a
  medium-risk user.
- **Some scripts deliberately refuse to produce a number.** #5 produces no blended posture score, #16
  will not silently drop an unreachable estate from a compliance percentage. See section 6.
- **A failed data source is reported as `NOT QUERIED`, never as zero.** A missing cloud, a failed
  query and a genuinely clean result look identical in a total, and only one of them is good news.

---

## 2. Prerequisites

| Requirement | Detail |
|---|---|
| PowerShell | 5.1 or later |
| Azure | `Az.Accounts` plus, per script: `Az.Security`, `Az.PolicyInsights`, `Az.OperationalInsights`, `Az.Monitor`, `Az.FrontDoor`, `Az.KeyVault` |
| Graph | `Microsoft.Graph.Authentication` plus `Identity.SignIns`, `Identity.Governance`, `Identity.DirectoryManagement`, `Applications`, `Security`, `Reports` |
| AWS | `AWS.Tools.SecurityHub`, `AWS.Tools.CloudTrail`, `AWS.Tools.ConfigService`, `AWS.Tools.SimpleSystemsManagement` |
| OCI | The `oci` CLI, for the OCI half of #5 |
| Licensing | Entra ID **P2** for #3 (Identity Protection) and the PIM half of #4; Defender for Endpoint for #10; Defender for Cloud Apps for #17 |

Each script declares only the modules it actually needs. A script whose cloud is unreachable reports
that and continues with the rest rather than failing the whole run.

### Configuration

```powershell
Copy-Item .\Config\config.sample.json .\Config\config.json
```

Populate `itsm` (used by #1 and #10) and `vulnerability.apiBaseUrl` (#6).

**No secret of any kind is read from `config.json`.** Scanner API keys and the HIBP key are
SecureString parameters passed at run time. Azure and Graph use the ambient context.

---

## 3. Reporting

Nine read-only scripts, all safe to schedule.

```powershell
.\Get-PrivilegedAccountUsageReport.ps1 -LookbackHours 24 -OutputFormat HTML
.\Get-MultiCloudPostureReport.ps1      -IncludeCloud All
.\Get-CertificateExpiryReport.ps1      -Endpoint www.contoso.com,api.contoso.com:8443
.\Get-FirewallRuleChangeAudit.ps1      -LookbackHours 24
.\Get-CisBenchmarkCompliance.ps1       -NonCompliantOnly
.\Get-SiemLogSourceHealth.ps1          -ResourceGroupName rg-sec -WorkspaceName law-sec `
                                        -ExpectedDataType SecurityEvent,Syslog,SigninLogs
.\Get-ZeroTrustPolicyAudit.ps1
.\Get-PatchComplianceReport.ps1        -IncludeCloud All
.\Get-DataExfiltrationAlert.ps1        -ResourceGroupName rg-sec -WorkspaceName law-sec
```

Suggested cadence: **daily** #4, #12; **weekly** #5, #7, #8, #9, #14, #16, #17; **on demand** #13.

### Two of these need reading carefully

**`Get-SiemLogSourceHealth` — always pass `-ExpectedDataType`.** A log source that has been silent
*longer than the lookback window* has no recent record to be late, so it never appears in a last-seen
query. Without an explicit expectation list, a source that died last week is invisible and the report
looks clean. `-ExpectedDataType` is the only way to tell *quiet* from *gone*, and that difference is
the entire reason for the check.

**`Get-CertificateExpiryReport` checks what is served, not what is stored.** It opens a real TLS
connection to each endpoint. A certificate renewed in Key Vault or ACM but never bound to the
listener will pass every inventory check and still take the site down on expiry day. Certificate
validation is deliberately *not* enforced during the probe, so an already-expired or self-signed
certificate is reported as such instead of the endpoint appearing unreachable.

---

## 4. Ticketing (#1) — safe because it is idempotent

```powershell
.\New-DefenderAlertTicket.ps1 -MinimumSeverity High -LookbackHours 24
```

Not approval-gated — the workbook says ticketing is safe, and it is. But only if it is idempotent.
The ticketed alert set is persisted to a state file and written **immediately after each ticket**, so
a failure halfway through a batch cannot cause those alerts to be ticketed again on the next run.

`-MaxTickets` caps a single run at 50 and logs when it truncates. The dangerous failure here is not
one wrong ticket, it is a thousand right ones during an alert storm.

If the state file is unreadable, the script says so and treats every alert as new — expect duplicates
that run, and fix the file.

---

## 5. The gated rows

### #3 Risky user remediation — the parameter set enforces the guardrail

```powershell
.\Invoke-EntraRiskyUserRemediation.ps1 -Action RevokeSessions           # report + approval
.\Invoke-EntraRiskyUserRemediation.ps1 -Action RevokeSessions -ApprovalReference APR-...
.\Invoke-EntraRiskyUserRemediation.ps1 -Action BlockSignIn -LockoutAccepted -ApprovalReference APR-...
```

`-MinimumRiskLevel` accepts **only** `high`. Medium and low risk users are reported and are
structurally not actionable — a parameter that could be widened would not honour a guardrail that
says ambiguous cases go to an analyst.

The three actions are ordered by what they cost when wrong:

| Action | Cost of a false positive |
|---|---|
| `RevokeSessions` (default) | A re-authentication |
| `ConfirmCompromised` | A risk record to dismiss |
| `BlockSignIn` | A real user loses their working day — needs `-LockoutAccepted` **on top of** the approval |

### #2 Phishing triage — will not block a sender

```powershell
.\Invoke-SentinelPhishingTriage.ps1 -ResourceGroupName rg-sec -WorkspaceName law-sec `
    -KnownPatternFile .\patterns.json
```

`-KnownPatternFile` is mandatory and there is no default. Without it nothing is high-confidence and
nothing is eligible for closure — which is the correct failure mode, not a gap.

An incident is closed automatically **only** if it matches a pattern in that file. Everything else
stays open and is reported: a phishing incident closed wrongly is a real one nobody looks at again.

**Sender blocking is not performed under any flag.** Where the evidence supports one, the report names
the sender and says the decision is the analyst's. Blocking a sender has effects well beyond the
incident that prompted it.

### #10 EDR triage — no rule isolates anything

```powershell
.\Invoke-EdrAlertTriage.ps1 -LookbackHours 24 -ApprovalReference APR-...            # tickets only
.\Invoke-EdrAlertTriage.ps1 -IsolateDevice 'abc123' -ProductionImpactAssessed `
    -ApprovalReference APR-...                                                       # isolates one
```

Enrichment, device correlation and ticketing run for every qualifying alert. **Isolation runs for
nothing** unless three separate human acts line up: the device is named in `-IsolateDevice`,
`-ProductionImpactAssessed` is passed, and the approval is valid.

There is deliberately **no severity threshold that triggers isolation** — that would be exactly the
rule the guardrail says must not exist. Devices matching `-ProductionNamePattern` are refused
outright and that refusal cannot be overridden by any parameter; isolate those from the Defender
console through whatever change process fits a production outage.

### #15 WAF — always lands in Detection

```powershell
.\Update-CloudWafRuleSet.ps1 -ResourceGroupName rg-waf -PolicyName wafpolicy01 `
    -ManagedRuleSetVersion 2.1 -ApprovalReference APR-...
# later, after reviewing the detection logs
.\Update-CloudWafRuleSet.ps1 -ResourceGroupName rg-waf -PolicyName wafpolicy01 `
    -ManagedRuleSetVersion 2.1 -PromoteToPrevention -DetectionResultsValidated -ApprovalReference APR-...
```

A managed rule set update in Detection mode is safe — it logs what it would block and blocks nothing.
The same update in Prevention mode can start refusing legitimate traffic the moment it applies, and
the first symptom is usually a customer complaint rather than an alert.

So updates always land in Detection. Promotion is a separate run with a separate flag. **Custom rules
are never modified** — they are counted, named and left alone.

Only Azure Front Door is implemented. AWS WAF and OCI WAF have different managed-rule models.

### #18 Secret rotation — the inventory is the gate

```powershell
.\Update-ServiceAccountSecret.ps1 -DependencyInventoryFile .\deps.json -KeyVaultName kv-prod
```

An application absent from `-DependencyInventoryFile` is reported as needing discovery and is
**structurally not rotatable**. Rotating a secret is trivial; knowing what stops working when you do
is not, and that knowledge does not live in any API.

`-RemoveOldSecret` is **off by default**. The overlap window — both secrets valid until consumers have
moved — is what turns a rotation from an outage into a change.

**One honest limitation:** Microsoft Graph returns a new client secret as a plain .NET string and
offers no alternative. The script builds a SecureString from it character by character and clears the
source property immediately, but the string existed in managed memory and .NET strings cannot be
zeroed. That is a property of the Graph API, not of this script.

### #11 Access reviews — the one engine exception

```powershell
.\Start-AccessReviewCampaign.ps1 -GroupName 'Finance-Contributors' -DurationDays 14
.\Start-AccessReviewCampaign.ps1 -CompileResults -ChaseAfterDays 7
```

This is the only script in the whole library that writes while being agent-assist with no approval
gate, and the reason is worth stating: the automatable half **is** the write. Launching a campaign,
chasing reviewers and compiling results is mechanical. The keep/revoke decision is made by each
manager inside the review UI days later — somewhere this script could not gate even in principle.

The safety that replaces the gate: **`autoApplyDecisionsEnabled` is `false`** on every campaign
created, and the script never sets a decision on anyone's behalf.

---

## 6. Where these scripts refuse to give you a number

You may be asked for a single figure by three of these reports. Two of them will not produce one, and
the third qualifies it. This is deliberate.

**#5 CSPM produces no blended score.** Azure Secure Score, AWS Security Hub and OCI Cloud Guard
measure different control sets, on different scales, with different weightings. An average of them
moves for reasons nobody can explain and means nothing to any of the three teams. Each cloud is
reported on its own scale, and **finding counts by severity — which are comparable — are totalled**.
A cloud that could not be queried is `NOT QUERIED`, because a missing cloud silently improves any
total it is left out of.

**#16 patch compliance** gives a combined percentage over **only the platforms that answered**, and
names them. A failed platform is `NOT QUERIED`, not counted as zero machines: dropping an estate from
the denominator makes the number go up, which is the wrong direction for a compliance figure to move
by accident.

**#9 CIS** reports what the cloud's own policy engine already evaluated and implements no benchmark
checks of its own. If no CIS initiative is assigned in Azure Policy, it reports that **nothing is
being evaluated** — not zero failures, which would read as a clean bill of health for a benchmark
nobody is running.

---

## 7. Audit trail

Every script logs through `Write-AutomationLog` — timestamp, level, target, acting script — and
credential-shaped strings are redacted before anything is written, including API error text.

Approval artifacts live in `%ProgramData%\ITAutomation\Approvals`. A reference is single-script and
expires; it cannot be replayed against a different action.

---

## 8. Known limitations

- **No script in this category has been executed against a real tenant, subscription or scanner.**
  Validation is static analysis (`Invoke-ScriptAnalyzer`, 0 findings), AST parse, and module-level
  unit tests with mocked inputs.
- **#6**: Tenable.io is the implemented path. Qualys endpoint paths differ between deployments and
  should be verified.
- **#8**: appliance firewalls (Palo Alto and similar) are not covered — their change logs live on the
  appliance and need their own credentials. Azure Activity Log and AWS CloudTrail both retain 90 days
  by default, and a longer lookback is reported as incomplete rather than short.
- **#15**: Azure Front Door only.
- **#3, #4**: require Entra ID P2. Without it the risk endpoints return nothing, which the scripts
  report as missing licensing rather than as a clean result.
- **#17**: depends on the `CloudAppEvents` table being present in the workspace. If the query fails
  it is reported as *not collected* — which is not the same as no exfiltration.
