<#
.SYNOPSIS
    Reports patch compliance across Azure and AWS estates.

.DESCRIPTION
    Collects patch compliance from Azure Update Manager and AWS Systems
    Manager and reports a percentage per platform, plus a combined figure
    covering only the platforms that actually answered.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Azure subscription to operate in. The current context when omitted.

.PARAMETER IncludeCloud
    Which platforms to query.

.PARAMETER AwsRegion
    AWS region for Systems Manager.

.PARAMETER NonCompliantOnly
    Report only machines missing patches.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-PatchComplianceReport.ps1 -IncludeCloud All -OutputFormat HTML

    Patch compliance across both clouds.

.EXAMPLE
    .\Get-PatchComplianceReport.ps1 -IncludeCloud AWS -AwsRegion me-central-1 -NonCompliantOnly

    AWS machines missing patches.

.NOTES
    Source use case      : #16 - Patch Tuesday Compliance Report
    Category             : Security Cloud
    Technology           : WSUS / SCCM / Az Update Mgr / SSM
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Unified cross-platform compliance %"

    Required permissions : Reader on the Azure subscription; ssm:DescribeInstancePatchStates in AWS.
    Required modules     : Az.Accounts
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    The combined percentage covers only the platforms that responded, and
    it says which those were. A platform that failed to answer is reported
    as NOT QUERIED rather than counted as zero machines - dropping an
    estate from the denominator makes the number go up, which is exactly
    the wrong direction for a compliance report to move by accident.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [ValidateSet('Azure','AWS','All')]
    [string[]]$IncludeCloud = @('All'),

    [string]$AwsRegion,

    [switch]$NonCompliantOnly,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-PatchComplianceReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #16 (Security Cloud)'

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
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        $wanted = if ($IncludeCloud -contains 'All') { @('Azure', 'AWS') } else { $IncludeCloud }
        $platformStats = @{}

        if ($wanted -contains 'Azure') {
            try {
                $azContext = Get-AzContext -ErrorAction Stop
                if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
                    $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
                }

                $query = @{
                    query = @(
                        'patchassessmentresources'
                        "| where type =~ 'microsoft.compute/virtualmachines/patchassessmentresults/softwarepatches'"
                        '| extend vmId = tostring(split(id, "/patchAssessmentResults/")[0])'
                        '| summarize Pending = count() by vmId'
                    ) -join ' '
                } | ConvertTo-Json -Compress

                $response = Invoke-AzRestMethod -Method POST -Payload $query `
                    -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' -ErrorAction Stop
                if ($response.StatusCode -ge 400) {
                    throw ('Resource Graph query failed (HTTP {0}): {1}' -f $response.StatusCode, $response.Content)
                }
                $rows = @(($response.Content | ConvertFrom-Json).data)

                $compliant = 0; $total = 0
                foreach ($row in $rows) {
                    $total++
                    $pending = [int]$row.Pending
                    if ($pending -eq 0) { $compliant++ }
                    if ($NonCompliantOnly -and $pending -eq 0) { continue }

                    $results.Add([PSCustomObject]@{
                        Name           = ($row.vmId -split '/')[-1]
                        Id             = $row.vmId
                        Cloud          = 'Azure'
                        MachineId      = $row.vmId
                        PendingPatches = $pending
                        Compliant      = ($pending -eq 0)
                        Status         = if ($pending -eq 0) { 'Compliant' } else { 'Missing patches' }
                        Detail         = ('{0} pending update(s)' -f $pending)
                    })
                }
                $platformStats['Azure'] = @{ Total = $total; Compliant = $compliant; Queried = $true }
            } catch {
                $platformStats['Azure'] = @{ Total = 0; Compliant = 0; Queried = $false }
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    'Azure patch compliance NOT collected: {0}' -f $_.Exception.Message)
            }
        }

        if ($wanted -contains 'AWS') {
            try {
                Import-Module AWS.Tools.SimpleSystemsManagement -ErrorAction Stop
                $stateParams = @{ ErrorAction = 'Stop' }
                if ($AwsRegion) { $stateParams.Region = $AwsRegion }
                $states = @(Get-SSMInstancePatchStatesForPatchGroup @stateParams -PatchGroup '*' -ErrorAction SilentlyContinue)
                if ($states.Count -eq 0) {
                    $states = @(Get-SSMInstancePatchState @stateParams)
                }

                $compliant = 0; $total = 0
                foreach ($state in $states) {
                    $total++
                    $missing = [int]$state.MissingCount + [int]$state.FailedCount
                    if ($missing -eq 0) { $compliant++ }
                    if ($NonCompliantOnly -and $missing -eq 0) { continue }

                    $results.Add([PSCustomObject]@{
                        Name           = $state.InstanceId
                        Id             = $state.InstanceId
                        Cloud          = 'AWS'
                        MachineId      = $state.InstanceId
                        PendingPatches = $missing
                        Compliant      = ($missing -eq 0)
                        Status         = if ($missing -eq 0) { 'Compliant' } else { 'Missing patches' }
                        Detail         = ('{0} missing, {1} failed, baseline {2}' -f
                                          $state.MissingCount, $state.FailedCount, $state.BaselineId)
                    })
                }
                $platformStats['AWS'] = @{ Total = $total; Compliant = $compliant; Queried = $true }
            } catch {
                $platformStats['AWS'] = @{ Total = 0; Compliant = 0; Queried = $false }
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    'AWS patch compliance NOT collected: {0}' -f $_.Exception.Message)
            }
        }

        $queriedPlatforms = @($platformStats.Keys | Where-Object { $platformStats[$_].Queried })
        $missedPlatforms = @($platformStats.Keys | Where-Object { -not $platformStats[$_].Queried })

        $grandTotal = 0; $grandCompliant = 0
        foreach ($platform in $queriedPlatforms) {
            $grandTotal += $platformStats[$platform].Total
            $grandCompliant += $platformStats[$platform].Compliant

            $results.Add([PSCustomObject]@{
                Name           = ('{0} compliance' -f $platform)
                Id             = ('summary-{0}' -f $platform)
                Cloud          = $platform
                MachineId      = ''
                PendingPatches = ($platformStats[$platform].Total - $platformStats[$platform].Compliant)
                Compliant      = $null
                Status         = 'Summary'
                Detail         = ('{0} of {1} compliant ({2}%)' -f
                                  $platformStats[$platform].Compliant, $platformStats[$platform].Total,
                                  $(if ($platformStats[$platform].Total -gt 0) {
                                      [math]::Round(($platformStats[$platform].Compliant / $platformStats[$platform].Total) * 100, 1)
                                    } else { 0 }))
            })
        }

        $results.Add([PSCustomObject]@{
            Name           = 'Combined compliance'
            Id             = 'summary-combined'
            Cloud          = 'ALL'
            MachineId      = ''
            PendingPatches = ($grandTotal - $grandCompliant)
            Compliant      = $null
            Status         = if ($missedPlatforms.Count -gt 0) { 'PARTIAL' } else { 'Complete' }
            Detail         = ('{0} of {1} machine(s) compliant ({2}%) across: {3}.{4}' -f
                              $grandCompliant, $grandTotal,
                              $(if ($grandTotal -gt 0) { [math]::Round(($grandCompliant / $grandTotal) * 100, 1) } else { 0 }),
                              ($queriedPlatforms -join ', '),
                              $(if ($missedPlatforms.Count -gt 0) {
                                  ' NOT QUERIED: ' + ($missedPlatforms -join ', ') + ' - those estates are absent from this figure.'
                                } else { '' }))
        })

        if ($missedPlatforms.Count -gt 0) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                'Combined compliance EXCLUDES {0}. Dropping an estate from the denominator raises the ' +
                'percentage; read this figure with that in mind.' -f ($missedPlatforms -join ', '))
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Patch Tuesday Compliance Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
