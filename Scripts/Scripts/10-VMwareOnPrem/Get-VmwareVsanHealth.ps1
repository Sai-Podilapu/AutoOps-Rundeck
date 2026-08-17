<#
.SYNOPSIS
    Reports vSAN cluster health, capacity and resync status.

.DESCRIPTION
    For each vSAN-enabled cluster, reports capacity and free space, disk group
    health, object compliance and any active resynchronisation. Resync
    activity matters because a cluster that is rebuilding is temporarily less
    able to survive another failure.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER VIServer
    vCenter server to connect to. Falls back to vmware.vCenterServer in
    config.json.

.PARAMETER Credential
    Credential for vCenter. Omit to use the PowerCLI credential store or SSPI.

.PARAMETER ClusterName
    Limit to VMs or hosts in specific clusters.

.PARAMETER MinimumFreePercent
    Flag a vSAN datastore below this free percentage.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-VmwareVsanHealth.ps1 -VIServer vcenter01 -OutputFormat HTML

    vSAN health report for every vSAN cluster.

.EXAMPLE
    .\Get-VmwareVsanHealth.ps1 -VIServer vcenter01 -ClusterName VSAN-PROD -MinimumFreePercent 30

    Checks one cluster against a 30% slack requirement.

.NOTES
    Source use case      : #13 - vSAN Health Info
    Category             : VMware OnPrem
    Technology           : PowerCLI / vSAN API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only"

    Required permissions : vSphere read-only role with vSAN view privileges.
    Required modules     : VMware.VimAutomation.Core
    Authentication       : Connect-VIServer with the PowerCLI credential store
                           or an explicit -Credential.

    vSAN best practice keeps 25-30% slack space for rebuilds and
    maintenance, which is why the default free-space floor here is higher
    than for a normal datastore.

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
    [int]$MinimumFreePercent = 25,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-VmwareVsanHealth'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #13 (VMware OnPrem)'

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
        $vsanFound = 0

        foreach ($cl in $clusters) {
            $isVsan = $false
            try { $isVsan = [bool]$cl.ExtensionData.ConfigurationEx.VsanConfigInfo.Enabled } catch { $isVsan = $false }
            if (-not $isVsan) { continue }
            $vsanFound++

            $ds = Get-Datastore -RelatedObject $cl -ErrorAction SilentlyContinue |
                  Where-Object { $_.Type -eq 'vsan' } | Select-Object -First 1

            $freePct = if ($ds -and $ds.CapacityGB -gt 0) {
                           [math]::Round(($ds.FreeSpaceGB / $ds.CapacityGB) * 100, 1)
                       } else { $null }

            $vmHosts = @(Get-VMHost -Location $cl)
            $diskGroups = 0; $unhealthyDisks = 0
            foreach ($h in $vmHosts) {
                try {
                    $dg = Get-VsanDiskGroup -VMHost $h -ErrorAction Stop
                    $diskGroups += @($dg).Count
                    foreach ($g in $dg) {
                        $unhealthyDisks += @(Get-VsanDisk -VsanDiskGroup $g -ErrorAction SilentlyContinue |
                            Where-Object { -not $_.IsCacheDisk -and $_.ExtensionData.OperationalState -ne 'ok' }).Count
                    }
                } catch {
                    Write-Verbose ('vSAN disk group detail unavailable on {0}' -f $h.Name)
                }
            }

            $resyncBytes = $null
            try {
                $resync = Get-VsanResyncingComponent -Cluster $cl -ErrorAction Stop
                $resyncBytes = ($resync | Measure-Object BytesLeftToResync -Sum).Sum
            } catch {
                Write-Verbose ('Resync detail unavailable for {0}' -f $cl.Name)
            }

            $issues = @()
            if ($null -ne $freePct -and $freePct -lt $MinimumFreePercent) { $issues += ('only {0}% free' -f $freePct) }
            if ($unhealthyDisks -gt 0)                                    { $issues += ('{0} disk(s) not healthy' -f $unhealthyDisks) }
            if ($resyncBytes -gt 0)                                       { $issues += 'resynchronisation in progress' }

            $results.Add([PSCustomObject]@{
                Name            = $cl.Name
                Id              = $cl.Id
                VsanEnabled     = $true
                HostCount       = $vmHosts.Count
                DiskGroups      = $diskGroups
                UnhealthyDisks  = $unhealthyDisks
                CapacityGB      = if ($ds) { [math]::Round($ds.CapacityGB, 1) } else { $null }
                FreeGB          = if ($ds) { [math]::Round($ds.FreeSpaceGB, 1) } else { $null }
                FreePercent     = $freePct
                ResyncBytesLeft = $resyncBytes
                ResyncActive    = ($resyncBytes -gt 0)
                Status          = if ($issues.Count) { 'Warning' } else { 'Healthy' }
                Issues          = ($issues -join '; ')
            })
            if ($issues.Count) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $cl.Name -Message ($issues -join '; ')
            }
        }

        if ($vsanFound -eq 0) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'No vSAN-enabled clusters found in scope.'
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'vSAN Health Info'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
