<#
.SYNOPSIS
    Reports Azure Load Balancer backend pool health.

.DESCRIPTION
    Checks each load balancer's backend pools for members and reports pools
    that are empty or whose probe configuration looks wrong. An empty backend
    pool is a silent outage - the load balancer answers, and nothing is behind
    it.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER LoadBalancerName
    Limit to specific load balancers.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AzLoadBalancerHealth.ps1 -OutputFormat HTML

    Backend pool health across the subscription.

.EXAMPLE
    .\Get-AzLoadBalancerHealth.ps1 -LoadBalancerName lb-prod

    One load balancer.

.NOTES
    Source use case      : #25 - Azure Load Balancer Health Probe Monitor
    Category             : Azure
    Technology           : Az Monitor / Alerts
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Alert on unhealthy backend pool members"

    Required permissions : Reader plus Monitoring Reader on the load balancer.
    Required modules     : Az.Accounts, Az.Network
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Per-member probe status is exposed through the Azure Monitor
    DipAvailability metric rather than the ARM resource. This script
    reports pool composition and probe configuration; wire the metric into
    an alert rule for live member health.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Network

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [string[]]$LoadBalancerName,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AzLoadBalancerHealth'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #25 (Azure)'

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

        $lbs = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzLoadBalancer -ResourceGroupName $_ } }
               else                    { Get-AzLoadBalancer }
        if ($LoadBalancerName) { $lbs = $lbs | Where-Object { $LoadBalancerName -contains $_.Name } }

        foreach ($lb in $lbs) {
            foreach ($pool in $lb.BackendAddressPools) {
                $memberCount = @($pool.BackendIpConfigurations).Count
                $rules = @($lb.LoadBalancingRules | Where-Object { $_.BackendAddressPool.Id -eq $pool.Id })
                $probeIds = @($rules.Probe.Id | Where-Object { $_ })
                $probes = @($lb.Probes | Where-Object { $probeIds -contains $_.Id })

                $issues = @()
                if ($memberCount -eq 0)            { $issues += 'BACKEND POOL IS EMPTY' }
                if ($rules.Count -eq 0)            { $issues += 'no load balancing rule references this pool' }
                if ($probes.Count -eq 0 -and $rules.Count -gt 0) { $issues += 'rules have no health probe' }
                foreach ($p in $probes) {
                    if ($p.IntervalInSeconds -gt 30) { $issues += ('probe {0} interval {1}s is slow to detect failure' -f $p.Name, $p.IntervalInSeconds) }
                }

                $results.Add([PSCustomObject]@{
                    Name          = ('{0} / {1}' -f $lb.Name, $pool.Name)
                    Id            = $pool.Id
                    LoadBalancer  = $lb.Name
                    ResourceGroup = $lb.ResourceGroupName
                    Location      = $lb.Location
                    Sku           = $lb.Sku.Name
                    BackendPool   = $pool.Name
                    MemberCount   = $memberCount
                    RuleCount     = $rules.Count
                    ProbeCount    = $probes.Count
                    Probes        = (($probes | ForEach-Object { '{0}({1}:{2}/{3}s)' -f $_.Name, $_.Protocol, $_.Port, $_.IntervalInSeconds }) -join '; ')
                    Status        = if ($issues.Count) { 'Warning' } else { 'OK' }
                    Issues        = ($issues -join '; ')
                })
                if ($issues.Count) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $lb.Name, $pool.Name) `
                        -Message ($issues -join '; ')
                }
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Load Balancer Health Probe Monitor'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
