<#
.SYNOPSIS
    Aggregates AWS Security Hub findings by severity and control.

.DESCRIPTION
    Pulls active Security Hub findings and aggregates them by severity,
    product and control so that a recurring control failure is visible as one
    line rather than a thousand.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER Severity
    Severity labels to include.

.PARAMETER MaxFindings
    Maximum findings to retrieve.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsSecurityHubFindingSummary.ps1 -Severity CRITICAL,HIGH

    Summarises only the two highest severities.

.EXAMPLE
    .\Get-AwsSecurityHubFindingSummary.ps1 -Region me-central-1 -OutputFormat HTML

    Writes an HTML summary.

.NOTES
    Source use case      : #7 - AWS Security Hub Findings Aggregation
    Category             : AWS
    Technology           : Security Hub / Lambda
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Daily summary of HIGH/CRITICAL findings; read-only"

    Required permissions : securityhub:GetFindings
    Required modules     : AWS.Tools.Common, AWS.Tools.SecurityHub
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.SecurityHub

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [string[]]$Severity = @('CRITICAL','HIGH','MEDIUM'),

    [ValidateRange(1,10000)]
    [int]$MaxFindings = 1000,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsSecurityHubFindingSummary'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #7 (AWS)'

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

        $filter = @{
            SeverityLabel   = @($Severity | ForEach-Object { @{ Comparison = 'EQUALS'; Value = $_ } })
            RecordState     = @(@{ Comparison = 'EQUALS'; Value = 'ACTIVE' })
            WorkflowStatus  = @(@{ Comparison = 'EQUALS'; Value = 'NEW' })
        }
        $findings = Get-SHUBFinding -Filter $filter -MaxResult $MaxFindings @awsArgs

        $findings | Group-Object { $_.Severity.Label }, { $_.ProductName }, { $_.Title } | ForEach-Object {
            $first = $_.Group[0]
            $results.Add([PSCustomObject]@{
                Name          = $first.Title
                Id            = $first.GeneratorId
                Severity      = $first.Severity.Label
                Product       = $first.ProductName
                Count         = $_.Count
                Resources     = (($_.Group.Resources.Id | Select-Object -Unique -First 5) -join '; ')
                FirstObserved = ($_.Group.FirstObservedAt | Sort-Object | Select-Object -First 1)
                Remediation   = $first.Remediation.Recommendation.Text
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Security Hub Findings Aggregation'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
