<#
.SYNOPSIS
    Reports Azure VMs that appear over-provisioned against observed CPU usage.

.DESCRIPTION
    Compares each VM's size against its observed CPU utilisation over the
    lookback window and flags candidates for downsizing. Reporting only - the
    resize itself is a separate, approval-gated action, which is what the
    workbook guardrail specifies.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER LookbackDays
    Metric window in days.

.PARAMETER UnderUtilisedCpuPercent
    Average CPU at or below which a VM is flagged as over-provisioned.

.PARAMETER MinimumSampleDays
    Require at least this many days of data before drawing a conclusion.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AzVmRightSizingReport.ps1 -LookbackDays 30 -OutputFormat HTML

    Right-sizing candidates over a month, as HTML.

.EXAMPLE
    .\Get-AzVmRightSizingReport.ps1 -ResourceGroupName rg-prod -UnderUtilisedCpuPercent 10

    Applies a stricter threshold to one resource group.

.NOTES
    Source use case      : #17 - Azure VM Right-Sizing Report
    Category             : Azure
    Technology           : Az Monitor / Advisor
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Report only; resizing itself would need approval"

    Required permissions : Reader plus Monitoring Reader on the target scope.
    Required modules     : Az.Accounts, Az.Compute, Az.Monitor
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    CPU alone does not justify a resize. A VM can be CPU-idle and
    memory-bound, and Azure does not expose guest memory without the
    diagnostics extension. Findings here are candidates for review, not
    instructions.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Compute
#Requires -Modules Az.Monitor

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [ValidateRange(1,90)]
    [int]$LookbackDays = 14,

    [ValidateRange(1,100)]
    [int]$UnderUtilisedCpuPercent = 20,

    [ValidateRange(1,90)]
    [int]$MinimumSampleDays = 7,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AzVmRightSizingReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #17 (Azure)'

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

        $vms = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ } }
               else                    { Get-AzVM }

        $from = (Get-Date).AddDays(-$LookbackDays)
        $to   = Get-Date

        foreach ($vm in $vms) {
            $metrics = $null
            try {
                $metrics = Get-AzMetric -ResourceId $vm.Id -MetricName 'Percentage CPU' `
                    -StartTime $from -EndTime $to -TimeGrain 01:00:00 -AggregationType Average -WarningAction SilentlyContinue
            } catch {
                Write-Verbose ('No CPU metric for {0}' -f $vm.Name)
            }

            $points = @($metrics.Data | Where-Object { $null -ne $_.Average })
            $sampleDays = [math]::Round($points.Count / 24, 1)

            # Not enough data is a different answer from "idle", and must not be
            # reported as a downsizing candidate.
            if ($points.Count -eq 0 -or $sampleDays -lt $MinimumSampleDays) {
                $results.Add([PSCustomObject]@{
                    Name = $vm.Name; Id = $vm.Id; ResourceGroup = $vm.ResourceGroupName
                    VmSize = $vm.HardwareProfile.VmSize
                    AvgCpuPercent = $null; MaxCpuPercent = $null; SampleDays = $sampleDays
                    Recommendation = 'Insufficient data'
                    Status = 'Unknown'
                })
                continue
            }

            $avg = [math]::Round((($points | Measure-Object Average -Average).Average), 1)
            $max = [math]::Round((($points | Measure-Object Average -Maximum).Maximum), 1)

            $status = if ($avg -le $UnderUtilisedCpuPercent -and $max -le ($UnderUtilisedCpuPercent * 2)) { 'Over-provisioned' }
                      elseif ($avg -ge 80) { 'Under-provisioned' }
                      else { 'Appropriate' }

            $results.Add([PSCustomObject]@{
                Name           = $vm.Name
                Id             = $vm.Id
                ResourceGroup  = $vm.ResourceGroupName
                Location       = $vm.Location
                VmSize         = $vm.HardwareProfile.VmSize
                AvgCpuPercent  = $avg
                MaxCpuPercent  = $max
                SampleDays     = $sampleDays
                Recommendation = switch ($status) {
                                     'Over-provisioned'  { 'Review for a smaller SKU - confirm memory headroom first' }
                                     'Under-provisioned' { 'Consider a larger SKU' }
                                     default             { 'No change indicated' }
                                 }
                Status         = $status
                Caveat         = 'CPU only. Memory and IO are not visible without the diagnostics extension.'
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure VM Right-Sizing Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
