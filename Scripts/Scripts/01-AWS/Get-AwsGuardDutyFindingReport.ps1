<#
.SYNOPSIS
    Reports GuardDuty findings above a severity threshold.

.DESCRIPTION
    Retrieves current GuardDuty findings for each detector, filtered by
    severity, with the affected resource and the finding type.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER MinimumSeverity
    GuardDuty numeric severity floor. 4 = medium, 7 = high.

.PARAMETER MaxFindings
    Maximum findings to retrieve per detector.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsGuardDutyFindingReport.ps1 -MinimumSeverity 7

    High severity findings only.

.EXAMPLE
    .\Get-AwsGuardDutyFindingReport.ps1 -Region me-central-1 -OutputFormat HTML

    HTML report for one region.

.NOTES
    Source use case      : #16 - AWS GuardDuty Findings Report
    Category             : AWS
    Technology           : GuardDuty API / Lambda
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Daily MEDIUM+ digest to ITSM"

    Required permissions : guardduty:ListDetectors, guardduty:ListFindings, guardduty:GetFindings
    Required modules     : AWS.Tools.Common, AWS.Tools.GuardDuty
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.GuardDuty

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [ValidateRange(1,10)]
    [double]$MinimumSeverity = 4,

    [ValidateRange(1,1000)]
    [int]$MaxFindings = 200,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsGuardDutyFindingReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #16 (AWS)'

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
        Connect-AutomationPlatform -Platform 'AWS' | Out-Null


        $awsArgs = @{}
        if ($Region)      { $awsArgs.Region = $Region }
        if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

        foreach ($d in (Get-GDDetectorList @awsArgs)) {
            $criteria = @{ Criterion = @{
                'severity'    = @{ GreaterThanOrEqual = $MinimumSeverity }
                'service.archived' = @{ Eq = @('false') }
            } }
            $ids = Get-GDFindingList -DetectorId $d -FindingCriteria $criteria -MaxResult $MaxFindings @awsArgs
            if (-not $ids) { continue }
            foreach ($f in (Get-GDFinding -DetectorId $d -FindingId $ids @awsArgs)) {
                $results.Add([PSCustomObject]@{
                    Name        = $f.Title
                    Id          = $f.Id
                    Severity    = $f.Severity
                    Type        = $f.Type
                    Resource    = $f.Resource.ResourceType
                    InstanceId  = $f.Resource.InstanceDetails.InstanceId
                    Region      = $f.Region
                    FirstSeen   = $f.Service.EventFirstSeen
                    LastSeen    = $f.Service.EventLastSeen
                    Count       = $f.Service.Count
                    Description = $f.Description
                })
            }
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS GuardDuty Findings Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
