<#
.SYNOPSIS
    Reports AWS cost anomalies detected by Cost Anomaly Detection.

.DESCRIPTION
    Retrieves detected cost anomalies for the lookback period with their
    impact, root cause and the monitor that raised them.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER ProfileName
    Named AWS profile / SSO profile to use. Prefer an IAM role where the host
    supports one.

.PARAMETER LookbackDays
    How far back to retrieve anomalies.

.PARAMETER MinimumImpactUsd
    Ignore anomalies below this total impact.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AwsCostAnomalyReport.ps1 -LookbackDays 7

    Reports the last week of anomalies.

.EXAMPLE
    .\Get-AwsCostAnomalyReport.ps1 -MinimumImpactUsd 500 -OutputFormat HTML

    Only material anomalies, as HTML.

.NOTES
    Source use case      : #8 - AWS Cost Explorer Anomaly Alerts
    Category             : AWS
    Technology           : Cost Anomaly Detection / SNS
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Alerting only"

    Required permissions : ce:GetAnomalies
    Required modules     : AWS.Tools.Common, AWS.Tools.CostExplorer
    Authentication       : IAM role or SSO profile via Set-AWSCredential. Never
                           an access key pair in code.

    Cost Explorer APIs are billed per request. Scheduling this hourly is
    expensive for no benefit - anomaly detection runs daily.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules AWS.Tools.Common
#Requires -Modules AWS.Tools.CostExplorer

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$ProfileName,

    [ValidateRange(1,365)]
    [int]$LookbackDays = 30,

    [double]$MinimumImpactUsd = 50,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AwsCostAnomalyReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #8 (AWS)'

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


        $awsArgs = @{ Region = 'us-east-1' }   # Cost Explorer is a global endpoint
        if ($ProfileName) { $awsArgs.ProfileName = $ProfileName }

        $start = (Get-Date).AddDays(-$LookbackDays).ToString('yyyy-MM-dd')
        $end   = (Get-Date).ToString('yyyy-MM-dd')

        $anoms = Get-CEAnomaly -DateInterval_StartDate $start -DateInterval_EndDate $end @awsArgs
        foreach ($a in $anoms) {
            if ($a.Impact.TotalImpact -lt $MinimumImpactUsd) { continue }
            $results.Add([PSCustomObject]@{
                Name           = ($a.RootCauses | Select-Object -First 1 -Expand Service)
                Id             = $a.AnomalyId
                StartDate      = $a.AnomalyStartDate
                EndDate        = $a.AnomalyEndDate
                TotalImpactUsd = [math]::Round($a.Impact.TotalImpact, 2)
                MaxImpactUsd   = [math]::Round($a.Impact.MaxImpact, 2)
                Feedback       = $a.Feedback
                RootCauses     = (($a.RootCauses | ForEach-Object { "$($_.Service)/$($_.Region)/$($_.UsageType)" }) -join '; ')
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AWS Cost Explorer Anomaly Alerts'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
