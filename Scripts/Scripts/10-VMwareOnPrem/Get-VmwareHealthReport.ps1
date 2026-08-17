<#
.SYNOPSIS
    Reports vSphere host, cluster and datastore health.

.DESCRIPTION
    Collects the health signals that matter on a vSphere estate: host
    connection and maintenance state, CPU and memory headroom per cluster,
    datastore free space, HA and DRS configuration, and triggered vCenter
    alarms. Reports HA admission-control headroom, because a cluster that is
    healthy today but cannot absorb a host failure is the situation this
    catches.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER VIServer
    vCenter server to connect to. Falls back to vmware.vCenterServer in
    config.json.

.PARAMETER Credential
    Credential for vCenter. Omit to use the PowerCLI credential store or SSPI.

.PARAMETER ClusterName
    Limit to VMs or hosts in specific clusters.

.PARAMETER MinimumDatastoreFreePercent
    Flag datastores below this free percentage.

.PARAMETER MaxMemoryUsagePercent
    Flag hosts above this memory usage.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-VmwareHealthReport.ps1 -VIServer vcenter01 -OutputFormat HTML

    Full estate health report as HTML.

.EXAMPLE
    .\Get-VmwareHealthReport.ps1 -VIServer vcenter01 -ClusterName PROD -MinimumDatastoreFreePercent 25

    Checks one cluster with a tighter datastore threshold.

.NOTES
    Source use case      : #5 - VMware Health Check
    Category             : VMware OnPrem
    Technology           : PowerCLI / vROps
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only report"

    Required permissions : vSphere read-only role.
    Required modules     : VMware.VimAutomation.Core
    Authentication       : Connect-VIServer with the PowerCLI credential store
                           or an explicit -Credential.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$VIServer,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [string[]]$ClusterName,

    [ValidateRange(1,99)]
    [int]$MinimumDatastoreFreePercent = 15,

    [ValidateRange(1,100)]
    [int]$MaxMemoryUsagePercent = 85,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-VmwareHealthReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #5 (VMware OnPrem)'

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
        Connect-AutomationPlatform -Platform 'VMware' | Out-Null


        if (-not $VIServer -and $config -and $config.vmware) { $VIServer = $config.vmware.vCenterServer }
        if (-not $VIServer) { throw 'No vCenter specified. Pass -VIServer or set vmware.vCenterServer in config.json.' }

        $viParams = @{ Server = $VIServer; ErrorAction = 'Stop' }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $viParams.Credential = $Credential }
        $vc = Connect-VIServer @viParams
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $VIServer -Message (
            'Connected to vCenter {0} (version {1})' -f $vc.Name, $vc.Version)

        $clusters = if ($ClusterName) { Get-Cluster -Name $ClusterName } else { Get-Cluster }

        foreach ($cl in $clusters) {
            $hosts    = @(Get-VMHost -Location $cl)
            $connected= @($hosts | Where-Object { $_.ConnectionState -eq 'Connected' })
            $maint    = @($hosts | Where-Object { $_.ConnectionState -eq 'Maintenance' })

            $totalMem = ($hosts | Measure-Object MemoryTotalGB -Sum).Sum
            $usedMem  = ($hosts | Measure-Object MemoryUsageGB -Sum).Sum
            $memPct   = if ($totalMem -gt 0) { [math]::Round(($usedMem / $totalMem) * 100, 1) } else { 0 }

            $totalCpu = ($hosts | Measure-Object CpuTotalMhz -Sum).Sum
            $usedCpu  = ($hosts | Measure-Object CpuUsageMhz -Sum).Sum
            $cpuPct   = if ($totalCpu -gt 0) { [math]::Round(($usedCpu / $totalCpu) * 100, 1) } else { 0 }

            # Can the cluster still absorb one host failure? That is the question HA
            # admission control exists to answer, and it is not visible from usage alone.
            $perHostMem = if ($hosts.Count -gt 0) { $totalMem / $hosts.Count } else { 0 }
            $survivesHostLoss = ($totalMem - $perHostMem) -gt $usedMem

            $issues = @()
            if ($maint.Count -gt 0)                         { $issues += ('{0} host(s) in maintenance' -f $maint.Count) }
            if ($connected.Count -ne $hosts.Count - $maint.Count) { $issues += 'host(s) not connected' }
            if ($memPct -ge $MaxMemoryUsagePercent)         { $issues += ('cluster memory {0}%' -f $memPct) }
            if (-not $survivesHostLoss)                     { $issues += 'CANNOT absorb a single host failure' }
            if (-not $cl.HAEnabled)                         { $issues += 'HA disabled' }

            $results.Add([PSCustomObject]@{
                Name              = $cl.Name
                Id                = $cl.Id
                Type              = 'Cluster'
                HostsTotal        = $hosts.Count
                HostsConnected    = $connected.Count
                HostsInMaintenance= $maint.Count
                CpuUsagePercent   = $cpuPct
                MemoryUsagePercent= $memPct
                HAEnabled         = $cl.HAEnabled
                DrsEnabled        = $cl.DrsEnabled
                DrsAutomation     = "$($cl.DrsAutomationLevel)"
                SurvivesHostLoss  = $survivesHostLoss
                Status            = if ($issues.Count) { 'Warning' } else { 'OK' }
                Issues            = ($issues -join '; ')
            })
        }

        foreach ($ds in (Get-Datastore)) {
            $freePct = if ($ds.CapacityGB -gt 0) { [math]::Round(($ds.FreeSpaceGB / $ds.CapacityGB) * 100, 1) } else { 0 }
            $low = $freePct -lt $MinimumDatastoreFreePercent
            $results.Add([PSCustomObject]@{
                Name        = $ds.Name
                Id          = $ds.Id
                Type        = 'Datastore'
                CapacityGB  = [math]::Round($ds.CapacityGB, 1)
                FreeGB      = [math]::Round($ds.FreeSpaceGB, 1)
                FreePercent = $freePct
                DatastoreType = $ds.Type
                Status      = if ($low) { 'Warning' } else { 'OK' }
                Issues      = if ($low) { ('only {0}% free' -f $freePct) } else { '' }
            })
            if ($low) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $ds.Name `
                    -Message ('Datastore {0}% free, below the {1}% floor' -f $freePct, $MinimumDatastoreFreePercent)
            }
        }

        foreach ($alarm in (Get-VMHost | Get-View | Where-Object { $_.TriggeredAlarmState })) {
            foreach ($a in $alarm.TriggeredAlarmState) {
                $results.Add([PSCustomObject]@{
                    Name   = $alarm.Name
                    Id     = "$($a.Key)"
                    Type   = 'Alarm'
                    Status = "$($a.OverallStatus)"
                    Issues = 'triggered vCenter alarm'
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'VMware Health Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
