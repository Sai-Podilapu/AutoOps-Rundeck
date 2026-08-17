<#
.SYNOPSIS
    Reports Azure VM patch compliance from Update Manager assessment data.

.DESCRIPTION
    Reads the last patch assessment for each VM and reports pending updates by
    classification, flagging VMs with outstanding critical or security patches
    and VMs whose assessment is itself stale. Reporting only - patch execution
    is a separate approval-gated action.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER StaleAssessmentDays
    Flag a VM whose last assessment is older than this.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AzVmPatchComplianceReport.ps1 -OutputFormat HTML

    Patch compliance across the subscription.

.EXAMPLE
    .\Get-AzVmPatchComplianceReport.ps1 -ResourceGroupName rg-prod -StaleAssessmentDays 3

    Tighter staleness threshold.

.NOTES
    Source use case      : #29 - Azure VM Patch Compliance Report
    Category             : Azure
    Technology           : Az Update Manager / Log Analytics
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Report only; patch execution would need approval"

    Required permissions : Reader plus Virtual Machine Contributor (assessment data requires it).
    Required modules     : Az.Accounts, Az.Compute
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Requires Azure Update Manager assessment to have run at least once per
    VM. A VM that has never been assessed is reported as Unknown rather
    than compliant - never assessed is not the same as no missing patches.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Compute

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [ValidateRange(1,365)]
    [int]$StaleAssessmentDays = 7,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AzVmPatchComplianceReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #29 (Azure)'

    try {
        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }
        # Recorded so an audit can tell which environment a run targeted.
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Configuration loaded for environment: {0}' -f $config.environment)
    } catch {
        # Read-only: config only supplies optional notification endpoints,
        # so its absence must not stop a report from being produced.
        $config = $null
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Config unavailable ({0}); continuing because this script only reads.' -f $_.Exception.Message)
    }

    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    try {
        Connect-AutomationPlatform -Platform 'Azure' | Out-Null


        if (-not $SubscriptionId -and $config -and $config.azure) { $SubscriptionId = $config.azure.defaultSubscriptionId }
        if ($SubscriptionId) {
            Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Subscription context: {0}' -f $SubscriptionId)
        } else {
            $ctx = Get-AzContext
            if (-not $ctx) { throw 'No Azure context. Pass -SubscriptionId or set azure.defaultSubscriptionId in config.json.' }
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'No -SubscriptionId given; using the ambient context {0}' -f $ctx.Subscription.Id)
        }

        $vms = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ } }
               else                    { Get-AzVM }

        foreach ($vm in $vms) {
            $assessment = $null
            try {
                $uri = ('{0}/patchAssessmentResults/latest?api-version=2023-03-01' -f $vm.Id)
                $resp = Invoke-AzRestMethod -Path $uri -Method GET -ErrorAction Stop
                if ($resp.StatusCode -lt 400) { $assessment = ($resp.Content | ConvertFrom-Json).properties }
            } catch {
                Write-Verbose ('No assessment data for {0}' -f $vm.Name)
            }

            if (-not $assessment) {
                $results.Add([PSCustomObject]@{
                    Name = $vm.Name; Id = $vm.Id; ResourceGroup = $vm.ResourceGroupName
                    OsType = "$($vm.StorageProfile.OsDisk.OsType)"
                    LastAssessment = $null; AssessmentAgeDays = $null
                    CriticalPending = $null; SecurityPending = $null; OtherPending = $null
                    Status = 'Unknown'
                    Issues = 'never assessed - not the same as compliant'
                })
                continue
            }

            $ageDays = if ($assessment.startDateTime) {
                           [math]::Round(((Get-Date) - [datetime]$assessment.startDateTime).TotalDays, 1)
                       } else { $null }

            $critical = [int]$assessment.availablePatchCountByClassification.critical
            $security = [int]$assessment.availablePatchCountByClassification.security
            $other    = [int]$assessment.availablePatchCountByClassification.other +
                        [int]$assessment.availablePatchCountByClassification.updateRollup

            $issues = @()
            if ($critical -gt 0) { $issues += ('{0} critical pending' -f $critical) }
            if ($security -gt 0) { $issues += ('{0} security pending' -f $security) }
            if ($null -ne $ageDays -and $ageDays -gt $StaleAssessmentDays) { $issues += ('assessment {0}d old' -f $ageDays) }

            $results.Add([PSCustomObject]@{
                Name              = $vm.Name
                Id                = $vm.Id
                ResourceGroup     = $vm.ResourceGroupName
                OsType            = "$($vm.StorageProfile.OsDisk.OsType)"
                LastAssessment    = $assessment.startDateTime
                AssessmentAgeDays = $ageDays
                CriticalPending   = $critical
                SecurityPending   = $security
                OtherPending      = $other
                RebootPending     = $assessment.rebootPending
                Status            = if ($critical -gt 0 -or $security -gt 0) { 'NonCompliant' }
                                    elseif ($issues.Count) { 'Warning' } else { 'Compliant' }
                Issues            = ($issues -join '; ')
            })
        }
    } catch {
        $msg = $_.Exception.Message
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message ('Discovery FAILED: {0}' -f $msg)
        $failures.Add([PSCustomObject]@{ Stage = 'Discovery'; Error = $msg })
    }
}

end {
    $candidates = @($results)

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message ('Collected {0} record(s).' -f $candidates.Count)
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure VM Patch Compliance Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
