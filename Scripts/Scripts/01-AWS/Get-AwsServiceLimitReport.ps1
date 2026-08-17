<#
.SYNOPSIS
    Reports AWS service quota usage against applied limits.

.DESCRIPTION
    Reads applied service quotas and flags any approaching its ceiling, which
    is the failure mode this use case exists to catch: a deployment that fails
    at 3am because an account silently hit a quota nobody was watching.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER Region
    AWS region to operate in. Defaults to the configured default region.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER ServiceCode
    Service codes to check, e.g. ec2, vpc, lambda.

.PARAMETER WarnAtPercent
    Usage percentage at or above which a quota is flagged.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsServiceLimitReport.ps1 -Region me-central-1

    Reports quota headroom for the default service list.

.EXAMPLE
    .\Get-AwsServiceLimitReport.ps1 -ServiceCode ec2,rds -WarnAtPercent 70 -OutputFormat HTML

    Checks two services at a tighter threshold and writes an HTML report.

.NOTES
    Source use case      : #2 - AWS Limit Monitor
    Category             : AWS
    Technology           : Lambda / CloudWatch
    Difficulty           : Low
    Agent possible       : Partial
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only monitoring; safe for full agent autonomy"

    Required permissions : servicequotas:ListServiceQuotas, cloudwatch:GetMetricData
    Required modules     : AWS.Tools.Common, AWS.Tools.ServiceQuotas
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.ServiceQuotas

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$Region,

    [string]$ProfileName,

    [string[]]$ServiceCode = @('ec2','vpc','lambda','rds','elasticloadbalancing'),

    [ValidateRange(1,100)]
    [int]$WarnAtPercent = 80,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsServiceLimitReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #2 (AWS)'

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

        foreach ($svc in $ServiceCode) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $svc -Message 'Reading applied quotas'
            $quotas = Get-SQServiceQuotaList -ServiceCode $svc @awsArgs
            foreach ($q in $quotas) {
                # Not every quota exposes a usage metric; those are reported with a null
                # usage rather than omitted, so the gap is visible instead of silent.
                $used = $null
                if ($q.UsageMetric -and $q.UsageMetric.MetricName) {
                    try {
                        $used = (Get-CWMetricStatistic -Namespace $q.UsageMetric.MetricNamespace `
                            -MetricName $q.UsageMetric.MetricName -Statistic Maximum `
                            -UtcStartTime (Get-Date).AddHours(-6) -UtcEndTime (Get-Date) -Period 3600 @awsArgs |
                            Select-Object -Expand Datapoints | Measure-Object -Property Maximum -Maximum).Maximum
                    } catch {
                        # Quota has no published usage metric, or CloudWatch has no
                        # datapoint yet. Reported as unknown usage, not as zero.
                        $used = $null
                    }
                }
                $pct = if ($null -ne $used -and $q.Value -gt 0) { [math]::Round(($used / $q.Value) * 100, 1) } else { $null }
                $results.Add([PSCustomObject]@{
                    Name        = $q.QuotaName
                    Id          = $q.QuotaCode
                    Service     = $svc
                    AppliedLimit= $q.Value
                    Used        = $used
                    PercentUsed = $pct
                    Adjustable  = $q.Adjustable
                    Status      = if ($null -eq $pct) { 'Unknown' } elseif ($pct -ge $WarnAtPercent) { 'Warning' } else { 'OK' }
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Limit Monitor'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
