<#
.SYNOPSIS
    Detects Azure cost spikes by comparing recent spend against a baseline.

.DESCRIPTION
    Queries Cost Management for daily cost by service over the lookback window
    and flags any service whose recent average exceeds its baseline average by
    more than the threshold. The workbook guardrail specifies alerting on
    spikes above 20%, which is the default here.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER LookbackDays
    Total window to query.

.PARAMETER RecentDays
    How many recent days form the comparison period.

.PARAMETER SpikeThresholdPercent
    Percentage increase over baseline at which a service is flagged.

.PARAMETER MinimumDailyCost
    Ignore services whose daily cost is below this. Stops trivial amounts
    generating noise.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AzCostAnomalyReport.ps1 -SpikeThresholdPercent 20

    Flags services whose recent spend is 20% above baseline.

.EXAMPLE
    .\Get-AzCostAnomalyReport.ps1 -LookbackDays 60 -RecentDays 7 -OutputFormat HTML

    Compares the last week against a two-month baseline.

.NOTES
    Source use case      : #13 - Azure Cost Anomaly Detection & Alerts
    Category             : Azure
    Technology           : Azure Cost Management + Logic Apps
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Auto-alert on cost spikes >20%"

    Required permissions : Cost Management Reader on the subscription.
    Required modules     : Az.Accounts, Az.CostManagement
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Cost Management data lags actual usage by up to 24 hours, and the most
    recent day is usually incomplete. -RecentDays defaults to 3 so a
    partial final day cannot on its own trigger a false spike.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.CostManagement

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [ValidateRange(7,365)]
    [int]$LookbackDays = 30,

    [ValidateRange(1,30)]
    [int]$RecentDays = 3,

    [ValidateRange(1,1000)]
    [int]$SpikeThresholdPercent = 20,

    [double]$MinimumDailyCost = 5,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AzCostAnomalyReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #13 (Azure)'

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

        $end   = (Get-Date).Date.AddDays(-1)       # yesterday; today is always partial
        $start = $end.AddDays(-$LookbackDays)

        $scope = '/subscriptions/{0}' -f (Get-AzContext).Subscription.Id
        $query = @{
            type       = 'ActualCost'
            timeframe  = 'Custom'
            timePeriod = @{ from = $start.ToString('yyyy-MM-dd'); to = $end.ToString('yyyy-MM-dd') }
            dataset    = @{
                granularity = 'Daily'
                aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
                grouping    = @(@{ type = 'Dimension'; name = 'ServiceName' })
            }
        }

        $resp = Invoke-AzRestMethod -Path ("{0}/providers/Microsoft.CostManagement/query?api-version=2023-03-01" -f $scope) `
            -Method POST -Payload ($query | ConvertTo-Json -Depth 10) -ErrorAction Stop

        if ($resp.StatusCode -ge 400) {
            throw ('Cost Management query failed with HTTP {0}: {1}' -f $resp.StatusCode, $resp.Content)
        }

        $data = ($resp.Content | ConvertFrom-Json).properties
        $cols = $data.columns.name
        $iCost = [array]::IndexOf($cols, 'Cost')
        $iDate = [array]::IndexOf($cols, 'UsageDate')
        $iSvc  = [array]::IndexOf($cols, 'ServiceName')

        $recentCutoff = [int]$end.AddDays(-$RecentDays + 1).ToString('yyyyMMdd')

        $byService = @{}
        foreach ($row in $data.rows) {
            $svc  = $row[$iSvc]
            $cost = [double]$row[$iCost]
            $date = [int]$row[$iDate]
            if (-not $byService.ContainsKey($svc)) { $byService[$svc] = @{ Recent = @(); Baseline = @() } }
            if ($date -ge $recentCutoff) { $byService[$svc].Recent   += $cost }
            else                         { $byService[$svc].Baseline += $cost }
        }

        foreach ($svc in $byService.Keys) {
            $r = $byService[$svc].Recent
            $b = $byService[$svc].Baseline
            if ($r.Count -eq 0 -or $b.Count -eq 0) { continue }

            $recentAvg   = ($r | Measure-Object -Average).Average
            $baselineAvg = ($b | Measure-Object -Average).Average
            if ($recentAvg -lt $MinimumDailyCost) { continue }
            if ($baselineAvg -le 0) { continue }

            $pct = [math]::Round((($recentAvg - $baselineAvg) / $baselineAvg) * 100, 1)
            if ($pct -lt $SpikeThresholdPercent) { continue }

            $results.Add([PSCustomObject]@{
                Name           = $svc
                Id             = $svc
                RecentAvgDaily = [math]::Round($recentAvg, 2)
                BaselineAvgDaily = [math]::Round($baselineAvg, 2)
                IncreasePercent= $pct
                IncreaseDaily  = [math]::Round($recentAvg - $baselineAvg, 2)
                ProjectedMonthlyDelta = [math]::Round(($recentAvg - $baselineAvg) * 30, 2)
                RecentDays     = $RecentDays
                BaselineDays   = $b.Count
                Status         = 'Spike'
            })
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $svc -Message (
                'Cost spike {0}% - {1}/day vs {2}/day baseline' -f $pct, [math]::Round($recentAvg,2), [math]::Round($baselineAvg,2))
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Cost Anomaly Detection & Alerts'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
