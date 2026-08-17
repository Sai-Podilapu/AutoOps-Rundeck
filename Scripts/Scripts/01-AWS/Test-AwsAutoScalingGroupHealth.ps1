<#
.SYNOPSIS
    Checks Auto Scaling groups for unhealthy or out-of-balance capacity.

.DESCRIPTION
    Reports each ASG where the number of healthy in-service instances does not
    match desired capacity, or where instances are distributed unevenly across
    availability zones.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER AutoScalingGroupName
    Limit to specific groups.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Test-AwsAutoScalingGroupHealth.ps1 

    Checks every ASG in the region.

.EXAMPLE
    .\Test-AwsAutoScalingGroupHealth.ps1 -AutoScalingGroupName web-asg -OutputFormat JSON

    Checks one group.

.NOTES
    Source use case      : #13 - AWS Auto-Scaling Group Health Check
    Category             : AWS
    Technology           : Boto3 / CloudWatch
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Alert on unhealthy instances"

    Required permissions : autoscaling:DescribeAutoScalingGroups
    Required modules     : AWS.Tools.Common, AWS.Tools.AutoScaling
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.AutoScaling

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [string[]]$AutoScalingGroupName,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Test-AwsAutoScalingGroupHealth'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #13 (AWS)'

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
        if ($AutoScalingGroupName) { $awsArgs.AutoScalingGroupName = $AutoScalingGroupName }

        foreach ($g in (Get-ASAutoScalingGroup @awsArgs)) {
            $healthy = @($g.Instances | Where-Object { $_.HealthStatus -eq 'Healthy' -and $_.LifecycleState -eq 'InService' })
            $byAz = $g.Instances | Group-Object AvailabilityZone
            $spread = if ($byAz.Count -gt 0) { ($byAz | Measure-Object Count -Maximum).Maximum -
                                               ($byAz | Measure-Object Count -Minimum).Minimum } else { 0 }
            $issues = @()
            if ($healthy.Count -ne $g.DesiredCapacity) { $issues += "healthy $($healthy.Count) != desired $($g.DesiredCapacity)" }
            if ($spread -gt 1)                          { $issues += "AZ imbalance (spread $spread)" }

            $results.Add([PSCustomObject]@{
                Name            = $g.AutoScalingGroupName
                Id              = $g.AutoScalingGroupARN
                DesiredCapacity = $g.DesiredCapacity
                MinSize         = $g.MinSize
                MaxSize         = $g.MaxSize
                HealthyCount    = $healthy.Count
                TotalInstances  = $g.Instances.Count
                AzSpread        = $spread
                Status          = if ($issues.Count) { 'Degraded' } else { 'Healthy' }
                Issues          = ($issues -join '; ')
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Auto-Scaling Group Health Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
