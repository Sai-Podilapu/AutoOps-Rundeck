# SOP — Oracle Cloud Infrastructure Automation

Standard operating procedure for the fifteen OCI scripts in `Scripts/04-OCI`.

**Source:** `Agent_Automation_Feasibility_Assessment.xlsx`, sheet *OCI*, use cases #1–#15.

---

## 1. Prerequisites

| Requirement | Detail |
|---|---|
| PowerShell | 5.1 or later |
| Modules | **None.** Oracle ships no first-party OCI PowerShell module |
| OCI CLI | Required. These scripts wrap `oci` and parse its JSON |
| Shared module | `Modules/IT-Automation-Common.psm1` — imported automatically |
| Config | `Config/config.json` → `oci` |

```powershell
# Verify the CLI before anything else
oci --version
oci iam region list --output table
```

Every script resolves and verifies the CLI at start-up. A missing `oci` fails with an instruction
rather than a command-not-found.

### Authentication

Authentication comes entirely from the OCI CLI config profile — `~/.oci/config` and the API key it
points at. **No OCI credential is read from `config.json` and none appears in any script.** Set the
profile up once with `oci setup config`, or use instance principal / resource principal auth if the
scripts run on an OCI instance.

```powershell
.\Get-OciCompartmentInventory.ps1 -CliProfile PROD -Region me-dubai-1
```

The parameter is **`-CliProfile`, not `-Profile`** — `$Profile` is a PowerShell automatic variable
holding the path to your profile script, and binding a parameter to it would be a subtle and
unpleasant bug.

### Required IAM policies

| Script(s) | Policy |
|---|---|
| `Set-OciInstancePowerState` | `INSTANCE_POWER_ACTIONS`, `INSTANCE_INSPECT` |
| `New-OciInstance` | `INSTANCE_CREATE`, USE on the subnet, READ on the image |
| `New-OciBlockVolumeBackup` | `VOLUME_BACKUP_CREATE`, `VOLUME_INSPECT` |
| `New-OciBootVolumeBackup` | `BOOT_VOLUME_BACKUP_CREATE`, `VOLUME_ATTACHMENT_READ`, `INSTANCE_INSPECT` |
| `Get-OciBudgetAlert` | `BUDGET_INSPECT` at tenancy level |
| `Get-OciCompartmentInventory` | read `all-resources`, `COMPARTMENT_INSPECT` |
| `Set-OciResourceTagCompliance` | read `all-resources`, manage the types being tagged |
| `Get-OciIamAudit` | `USER_INSPECT`, `GROUP_INSPECT` at tenancy level |
| `Get-OciNetworkRuleReview` | `VCN_INSPECT`, `SECURITY_LIST_INSPECT`, NSG read |
| `Set-OciAutonomousDbState` | Autonomous DB START/STOP actions |
| `Get-OciLoadBalancerHealth` | `LOAD_BALANCER_INSPECT` |
| `Install-OciPatchUpdate` | OS Management instance actions + `BOOT_VOLUME_BACKUP_CREATE` |
| `Set-OciObjectLifecyclePolicy` | `OBJECTSTORAGE_BUCKET_UPDATE` |
| `Get-OciVcnFlowLogAnomaly` | `LOG_GROUP_INSPECT`, read on log content |
| `Invoke-OciDrPlanExecution` | `DR_PLAN_EXECUTION_CREATE`, inspect on DR protection groups |

Use a dedicated user or dynamic group. Grant the DR and lifecycle-policy rights only where they are
needed — those two scripts are the ones that can destroy data.

---

## 2. Configuration

```powershell
Copy-Item .\Config\config.sample.json .\Config\config.json
notepad .\Config\config.json
```

Populate the `oci` block: `profileName`, `defaultRegion`, `defaultCompartmentId`, `tenancyId`.
Budgets and IAM users live at **tenancy** level, not in a child compartment, which is why `tenancyId`
is separate.

`config.json` must never be committed. There is currently no `.gitignore` in this tree — exclude it
explicitly before any first commit.

---

## 3. Two things to set for your tenancy before first use

| Script | Parameter | Why |
|---|---|---|
| `Install-OciPatchUpdate` | `-OsManagementService` | OCI has **two** OS Management services — the newer Hub and the legacy one — with different CLI command groups. Which applies depends on the tenancy, so it is a parameter rather than a guess. Default `os-management-hub`. |
| `Invoke-OciDrPlanExecution` | `-DrCliGroup` | **Placeholder** default `disaster-recovery`. Verify against your CLI version. |

---

## 4. Reporting

The six read-only scripts are safe to schedule unattended.

```powershell
.\Get-OciCompartmentInventory.ps1 -SummaryOnly -IncludeSubcompartments
.\Get-OciIamAudit.ps1             -IssuesOnly -ApiKeyMaxAgeDays 90
.\Get-OciNetworkRuleReview.ps1    -OutputFormat HTML
.\Get-OciLoadBalancerHealth.ps1   -IssuesOnly -CertificateWarnDays 30
.\Get-OciBudgetAlert.ps1          -WarnAtPercent 80
```

### Reading these honestly

- **The inventory is a search result, not a billing-grade list.** The OCI resource search indexes most
  but not all resource types and updates asynchronously; a resource created seconds ago may not appear.
  The script says so in its log line rather than presenting the count as complete.
- **A federated user showing "no MFA" is not a finding on its own.** Federated identities are managed
  in the IdP and OCI has no record of their MFA state. `Get-OciIamAudit` words it as "no MFA recorded
  in OCI (federated — check the IdP)" rather than asserting a gap that may not exist.
- **A budget with no alert rule is a finding.** It tracks spend and tells nobody. Spend figures come
  from OCI's own Budgets API and are never recalculated here; OCI updates them periodically, so a
  budget crossed minutes ago may not show it yet.
- **`Get-OciNetworkRuleReview` changes nothing.** It ranks by exposure — `ALL` protocol or
  unrestricted ports is Critical, an administrative port is High, everything else open is Review — and
  stops. Whether 0.0.0.0/0 on 443 is correct depends entirely on what sits behind it.
- **A load balancer backend marked OK only means its health check passed.** It says nothing about
  whether the application is returning correct answers.

---

## 5. Power operations

```powershell
.\Set-OciInstancePowerState.ps1 -Action STOP  -TagKey schedule -TagValue nightly
.\Set-OciInstancePowerState.ps1 -Action START -InstanceName APP01,APP02 -WhatIf
.\Set-OciAutonomousDbState.ps1  -Action STOP  -TagKey schedule -TagValue dev
```

Selection must be explicit. Neither script will act on a whole compartment, and `-TagKey` without
`-TagValue` is refused as too broad for a power operation.

**Know which stop you are asking for.** `SOFTSTOP` and `SOFTRESET` ask the guest OS to shut down;
`STOP` and `RESET` pull the power and an in-flight write can be lost. Both are available because a
hung instance needs the hard form. A hard operation says so in the success log.

Stopping an Autonomous Database **terminates connected sessions**. That is fine for the dev
environments this is intended for and is not fine anywhere else, which is why selection defaults to
`schedule=dev`. `-DatabaseName` bypasses the tag filter for a named one-off, visibly and deliberately.

---

## 6. Backups

```powershell
.\New-OciBlockVolumeBackup.ps1 -VolumeName DATA01 -BackupType FULL
.\New-OciBlockVolumeBackup.ps1 -AssignPolicyName Silver     # let the platform keep taking them
.\New-OciBootVolumeBackup.ps1  -InstanceName APP01,APP02    # before a patch window
```

Boot volume backups default to **FULL** while block volume backups default to Incremental. That is
deliberate: a pre-patch snapshot whose restore depends on an earlier full backup still being intact
is not the safety net it appears to be, and a patch window is exactly when you do not want to find
that out.

---

## 7. Provisioning — what an approver is actually approving

```powershell
.\New-OciInstance.ps1 -DisplayName APP03 -Shape VM.Standard.E4.Flex -Ocpus 2 -MemoryInGBs 32 `
    -ImageId ocid1.image... -SubnetId ocid1.subnet...
```

The change set names the shape, OCPU count, memory, image and OS — the things that determine the
bill. The image and shape are validated against the compartment **before** the approval is raised, so
nobody approves a launch that cannot happen.

**No cost figure is computed.** OCI pricing depends on your tenancy agreement and there is no API
here that would make such a number true. The row says "Cost NOT calculated — price the shape against
your own rate card". An invented estimate on an approval artifact would be worse than none.

---

## 8. Tag compliance

```powershell
.\Set-OciResourceTagCompliance.ps1 -RequiredTag CostCenter,Owner
.\Set-OciResourceTagCompliance.ps1 -RequiredTag 'CostCenter=UNASSIGNED','Owner=itops' -AutoTag -WhatIf
```

OCI has no single tag-update call, so the script carries an explicit map of the types it can write:
instance, block volume, boot volume, VCN, subnet, bucket. **Anything else is reported as
non-compliant and marked as having no updater.** Silently counting it as compliant would be the easy
wrong answer.

Existing tags are merged before writing, because `--freeform-tags` replaces the whole map rather than
adding to it.

---

## 9. Patching — the pre-snapshot is not optional in practice

```powershell
.\Install-OciPatchUpdate.ps1 -InstanceName APP01 -UpdateType SECURITY          # report + approval
.\Install-OciPatchUpdate.ps1 -InstanceName APP01 -UpdateType SECURITY `
    -ApprovalReference APR-... -TicketReference CHG0012345
```

A FULL boot volume backup is taken **and waited on** before the patch call. An instance whose boot
volume cannot be resolved is **excluded entirely** rather than patched without a rollback point.

`-SkipPreSnapshot` exists, and it logs a WARN saying it contradicts the guardrail on this use case.
Use it only when you have a rollback route the script cannot see.

Patching may reboot the instance depending on the packages. The script neither suppresses nor forces
a reboot — schedule it inside the change window accordingly.

---

## 10. Object Storage lifecycle — a delayed destructive action

```powershell
.\Set-OciObjectLifecyclePolicy.ps1 -BucketName logs-archive -RulesFile .\lifecycle.json
.\Set-OciObjectLifecyclePolicy.ps1 -BucketName logs-archive -RulesFile .\lifecycle.json `
    -DeletionRulesReviewed -ApprovalReference APR-... -Execute
```

**This one is unusual and worth understanding before you run it.** Applying a lifecycle DELETE rule
destroys nothing at the moment you apply it. It destroys objects *continuously from then on*, without
further approval, as they age past the threshold. You are approving a standing instruction, not a
single action.

So the gate is on the rule set: a file containing any DELETE rule is **refused** until
`-DeletionRulesReviewed` is passed, and the change set states the standing effect in those words. The
previous policy is logged before being replaced — that log is your rollback. Objects already deleted
by a prior rule are not recoverable.

The rule array is normalised and re-serialised before it is sent, so what gets applied is exactly
what was reviewed, whatever shape the source file had.

---

## 11. Flow log analysis — a package, not a verdict

```powershell
.\Get-OciVcnFlowLogAnomaly.ps1 -LogGroupId ocid1.loggroup... -LookbackHours 24
```

Three queries: rejected-traffic concentrations, top talkers by volume, connections on unusual ports.
Every finding carries an `AnalystNote` giving the **benign** explanation, because a ranked list with
no counter-argument reads as a list of incidents when it is nothing of the sort.

Two results need care:

- **An empty result is ambiguous.** No traffic and no flow logging look identical to this query. The
  script says so rather than reporting all-clear.
- **Truncation makes the ranking unreliable.** Hitting `-MaxResults` is logged as a WARN saying the
  analysis is based on a truncated sample.

Interpretation and incident declaration are analyst work and are not attempted.

---

## 12. DR drill — the script runs the runbook, you make the calls

```powershell
.\Invoke-OciDrPlanExecution.ps1 -DrPlanId ocid1.drplan... -GoDecisionBy 'A. Rahman'
.\Invoke-OciDrPlanExecution.ps1 -DrPlanId ocid1.drplan... -GoDecisionBy 'A. Rahman' `
    -ApprovalReference APR-... -TicketReference CHG0012345 -Execute
```

The mechanical half is fully automated, and should be: a drill run by hand produces worse evidence
than one run by script. The evidence pack lands in `%ProgramData%\ITAutomation\Reports\DR` with the
execution id, plan type, approval and ticket references, and who gave the go.

Neither judgement is automated:

- `-GoDecisionBy` is **mandatory**. A drill with no named owner is not a governed drill.
- The evidence pack carries an explicit note that **PASS/FAIL is a drill-review decision** and is
  deliberately absent from it.

**The plan type is read before execution and a `FAILOVER` plan is refused without
`-FailoverAuthorized`.** The difference between a drill and moving production is one plan selection
in a list, which is exactly the kind of mistake a gate should catch.

Rollback depends entirely on plan type: a DRILL cleans up after itself, a SWITCHOVER is reversed by
switching back, and a FAILOVER has moved production with no undo.

---

## 13. Audit trail

Every script logs through `Write-AutomationLog` — timestamp, level, target, acting script — and
credential-shaped strings are redacted before anything is written, including CLI error text, which
can echo tokens.

Approval artifacts live in `%ProgramData%\ITAutomation\Approvals`. A reference is single-script and
expires; it cannot be replayed against a different action.

---

## 14. Known limitations

- **No script in this category has been executed against a real tenancy.** Validation is static
  analysis (`Invoke-ScriptAnalyzer`, 0 findings), AST parse, and module-level unit tests with mocked
  inputs. Run each in a test compartment first.
- **Two CLI command groups are placeholders or tenancy-dependent** (section 3).
- OCI CLI command surfaces change between versions. If a call fails with an unrecognised command,
  check it against `oci <group> --help` for your installed version before assuming the script is wrong.
- `Get-OciCompartmentInventory` depends on the search service being available in the region.
