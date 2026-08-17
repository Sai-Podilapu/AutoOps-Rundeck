<#
.SYNOPSIS
    Reports Azure Virtual Desktop host pool utilisation and session activity.

.DESCRIPTION
    For each host pool, reports session host availability, active and
    disconnected session counts, and hosts in drain mode. Disconnected
    sessions are reported separately from active ones, because a pool that
    looks busy is often holding sessions nobody is using.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER HostPoolName
    Limit to specific host pools.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AzAvdUtilizationReport.ps1 -OutputFormat HTML

    Utilisation report for every host pool.

.EXAMPLE
    .\Get-AzAvdUtilizationReport.ps1 -HostPoolName hp-prod -OutputFormat JSON

    One pool as JSON.

.NOTES
    Source use case      : #11 - AVD Utilization Report
    Category             : Azure
    Technology           : Az Monitor / Log Analytics
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only reporting"

    Required permissions : Desktop Virtualization Reader on the target scope.
    Required modules     : Az.Accounts, Az.DesktopVirtualization
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.DesktopVirtualization

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [string[]]$HostPoolName,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AzAvdUtilizationReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #11 (Azure)'

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

        $pools = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzWvdHostPool -ResourceGroupName $_ } }
                 else                    { Get-AzWvdHostPool }
        if ($HostPoolName) { $pools = $pools | Where-Object { $HostPoolName -contains $_.Name } }

        foreach ($pool in $pools) {
            $rg = ($pool.Id -split '/')[4]
            $hosts = @(Get-AzWvdSessionHost -ResourceGroupName $rg -HostPoolName $pool.Name -ErrorAction SilentlyContinue)
            $sessions = @(Get-AzWvdUserSession -ResourceGroupName $rg -HostPoolName $pool.Name -ErrorAction SilentlyContinue)

            $available = @($hosts | Where-Object { $_.Status -eq 'Available' })
            $draining  = @($hosts | Where-Object { $_.AllowNewSession -eq $false })
            $active    = @($sessions | Where-Object { $_.SessionState -eq 'Active' })
            $disc      = @($sessions | Where-Object { $_.SessionState -eq 'Disconnected' })

            $issues = @()
            if ($available.Count -eq 0 -and $hosts.Count -gt 0) { $issues += 'no session hosts available' }
            if ($draining.Count -gt 0)                          { $issues += ('{0} host(s) in drain mode' -f $draining.Count) }
            if ($disc.Count -gt $active.Count -and $disc.Count -gt 0) { $issues += 'more disconnected than active sessions' }

            $results.Add([PSCustomObject]@{
                Name              = $pool.Name
                Id                = $pool.Id
                ResourceGroup     = $rg
                HostPoolType      = "$($pool.HostPoolType)"
                LoadBalancerType  = "$($pool.LoadBalancerType)"
                MaxSessionLimit   = $pool.MaxSessionLimit
                SessionHostsTotal = $hosts.Count
                SessionHostsAvailable = $available.Count
                SessionHostsDraining  = $draining.Count
                ActiveSessions    = $active.Count
                DisconnectedSessions = $disc.Count
                TotalSessions     = $sessions.Count
                UtilisationPercent = if ($pool.MaxSessionLimit -gt 0 -and $hosts.Count -gt 0) {
                                         [math]::Round(($sessions.Count / ($pool.MaxSessionLimit * $hosts.Count)) * 100, 1)
                                     } else { $null }
                Status            = if ($issues.Count) { 'Warning' } else { 'OK' }
                Issues            = ($issues -join '; ')
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'AVD Utilization Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
