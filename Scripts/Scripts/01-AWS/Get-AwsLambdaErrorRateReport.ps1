<#
.SYNOPSIS
    Reports Lambda functions whose error rate exceeds a threshold.

.DESCRIPTION
    For each function, reads CloudWatch Invocations and Errors over the
    lookback window and reports the error rate. Functions with no invocations
    are reported as idle rather than as zero-error, because those are
    different facts.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER LookbackHours
    Metric window in hours.

.PARAMETER ErrorRateWarnPercent
    Error rate at or above which a function is flagged.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsLambdaErrorRateReport.ps1 -LookbackHours 6

    Checks the last six hours.

.EXAMPLE
    .\Get-AwsLambdaErrorRateReport.ps1 -ErrorRateWarnPercent 5 -OutputFormat CSV

    Flags above 5%, as CSV.

.NOTES
    Source use case      : #18 - AWS Lambda Function Error Rate Monitor
    Category             : AWS
    Technology           : CloudWatch / SNS
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Alert if error rate >5% for 5 min"

    Required permissions : lambda:ListFunctions, cloudwatch:GetMetricStatistics
    Required modules     : AWS.Tools.Common, AWS.Tools.Lambda, AWS.Tools.CloudWatch
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.Lambda
#Requires -Modules AWS.Tools.CloudWatch

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [ValidateRange(1,336)]
    [int]$LookbackHours = 24,

    [ValidateRange(0,100)]
    [double]$ErrorRateWarnPercent = 1,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsLambdaErrorRateReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #18 (AWS)'

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

        $from = (Get-Date).AddHours(-$LookbackHours)
        $to   = Get-Date

        foreach ($fn in (Get-LMFunctionList @awsArgs)) {
            $dim = @(@{ Name = 'FunctionName'; Value = $fn.FunctionName })
            $inv = (Get-CWMetricStatistic -Namespace 'AWS/Lambda' -MetricName 'Invocations' -Dimension $dim `
                    -Statistic Sum -UtcStartTime $from -UtcEndTime $to -Period 3600 @awsArgs |
                    Select-Object -Expand Datapoints | Measure-Object Sum -Sum).Sum
            $err = (Get-CWMetricStatistic -Namespace 'AWS/Lambda' -MetricName 'Errors' -Dimension $dim `
                    -Statistic Sum -UtcStartTime $from -UtcEndTime $to -Period 3600 @awsArgs |
                    Select-Object -Expand Datapoints | Measure-Object Sum -Sum).Sum

            $inv = [double]($inv | ForEach-Object { $_ }); if (-not $inv) { $inv = 0 }
            $err = [double]($err | ForEach-Object { $_ }); if (-not $err) { $err = 0 }
            $rate = if ($inv -gt 0) { [math]::Round(($err / $inv) * 100, 2) } else { $null }

            $results.Add([PSCustomObject]@{
                Name         = $fn.FunctionName
                Id           = $fn.FunctionArn
                Runtime      = $fn.Runtime
                Invocations  = $inv
                Errors       = $err
                ErrorRatePct = $rate
                Status       = if ($inv -eq 0) { 'Idle' }
                               elseif ($rate -ge $ErrorRateWarnPercent) { 'Warning' } else { 'OK' }
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Lambda Function Error Rate Monitor'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
