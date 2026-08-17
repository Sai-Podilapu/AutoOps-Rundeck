<#
.SYNOPSIS
    Reports the status of Route 53 health checks.

.DESCRIPTION
    Lists every Route 53 health check with its current status and the endpoint
    it monitors, flagging any that are unhealthy.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsRoute53HealthCheckStatus.ps1 

    Reports every health check.

.EXAMPLE
    .\Get-AwsRoute53HealthCheckStatus.ps1 -OutputFormat JSON

    Reports as JSON for downstream alerting.

.NOTES
    Source use case      : #21 - AWS Route53 Health Check Monitor
    Category             : AWS
    Technology           : Route53 / CloudWatch
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Alert on health check failures"

    Required permissions : route53:ListHealthChecks, route53:GetHealthCheckStatus
    Required modules     : AWS.Tools.Common, AWS.Tools.Route53
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.Route53

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$ProfileName,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsRoute53HealthCheckStatus'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #21 (AWS)'

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
        if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

        foreach ($hc in (Get-R53HealthCheckList @awsArgs)) {
            $obs = @()
            try {
                $obs = Get-R53HealthCheckStatus -HealthCheckId $hc.Id @awsArgs
            } catch {
                # Status is unavailable for a check that has not yet reported.
                Write-Verbose ('No status yet for health check {0}' -f $hc.Id)
            }
            $unhealthy = @($obs | Where-Object { $_.StatusReport.Status -notmatch 'Success' })
            $results.Add([PSCustomObject]@{
                Name        = if ($hc.HealthCheckConfig.FullyQualifiedDomainName) { $hc.HealthCheckConfig.FullyQualifiedDomainName }
                              else { $hc.HealthCheckConfig.IPAddress }
                Id          = $hc.Id
                Type        = $hc.HealthCheckConfig.Type
                Port        = $hc.HealthCheckConfig.Port
                ResourcePath= $hc.HealthCheckConfig.ResourcePath
                CheckerCount= $obs.Count
                UnhealthyCheckers = $unhealthy.Count
                Status      = if ($obs.Count -eq 0) { 'Unknown' }
                              elseif ($unhealthy.Count -eq 0) { 'Healthy' }
                              elseif ($unhealthy.Count -eq $obs.Count) { 'Unhealthy' }
                              else { 'Degraded' }
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Route53 Health Check Monitor'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
