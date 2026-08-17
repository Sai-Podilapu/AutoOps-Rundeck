<#
.SYNOPSIS
    Reports AWS Config rule compliance across the account.

.DESCRIPTION
    Summarises every AWS Config rule with its compliance state and the count
    of non-compliant resources, so a drifting rule is visible without opening
    the console.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER OnlyNonCompliant
    Report only rules that are currently non-compliant.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsConfigComplianceReport.ps1 -OnlyNonCompliant

    Reports just the failing rules.

.EXAMPLE
    .\Get-AwsConfigComplianceReport.ps1 -OutputFormat HTML

    Full compliance report as HTML.

.NOTES
    Source use case      : #14 - AWS Config Compliance Dashboard
    Category             : AWS
    Technology           : AWS Config / Lambda
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Non-compliant resource summary; read-only"

    Required permissions : config:DescribeConfigRules, config:DescribeComplianceByConfigRule
    Required modules     : AWS.Tools.Common, AWS.Tools.ConfigService
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.ConfigService

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [switch]$OnlyNonCompliant,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsConfigComplianceReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #14 (AWS)'

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

        foreach ($r in (Get-CFGConfigRule @awsArgs)) {
            $c = Get-CFGComplianceByConfigRule -ConfigRuleName $r.ConfigRuleName @awsArgs
            $state = $c.Compliance.ComplianceType
            if ($OnlyNonCompliant -and $state -ne 'NON_COMPLIANT') { continue }
            $results.Add([PSCustomObject]@{
                Name            = $r.ConfigRuleName
                Id              = $r.ConfigRuleId
                Compliance      = $state
                NonCompliantCount = $c.Compliance.ComplianceContributorCount.CappedCount
                RuleState       = $r.ConfigRuleState
                Source          = $r.Source.Owner
                Description     = $r.Description
                Status          = if ($state -eq 'NON_COMPLIANT') { 'NonCompliant' } else { 'OK' }
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Config Compliance Dashboard'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
