<#
.SYNOPSIS
    Reports Hyper-V host CPU, memory, storage and network health.

.DESCRIPTION
    Collects host-level capacity and headroom: logical processors against
    assigned virtual processors, physical memory against assigned VM memory,
    virtual hard disk path free space, and virtual switch state. Reports the
    overcommit ratio, which is the number that actually predicts trouble on a
    Hyper-V host.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER ComputerName
    Hyper-V host(s) to act against. Defaults to the local host.

.PARAMETER Credential
    Credential for the remote Hyper-V host.

.PARAMETER MinimumFreeDiskPercent
    Flag a host whose VHD storage drops below this.

.PARAMETER MaxCpuOvercommitRatio
    Flag a host whose virtual-to-logical processor ratio exceeds this.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-HvHostHealthReport.ps1 -ComputerName HV01,HV02 -OutputFormat HTML

    Health report for two hosts as HTML.

.EXAMPLE
    .\Get-HvHostHealthReport.ps1 -ComputerName HV01 -MaxCpuOvercommitRatio 2

    Applies a tighter overcommit threshold.

.NOTES
    Source use case      : #5 - Hyper-V Host Health Check
    Category             : Hyper-V
    Technology           : PowerShell / WMI
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "CPU/memory/network/storage report"

    Required permissions : Read access to Hyper-V WMI on the host.
    Required modules     : Hyper-V
    Authentication       : Integrated Kerberos over PSRemoting; SCVMM cmdlets
                           where noted.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Hyper-V

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [ValidateRange(1,100)]
    [int]$MinimumFreeDiskPercent = 15,

    [ValidateRange(1,64)]
    [double]$MaxCpuOvercommitRatio = 4,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-HvHostHealthReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #5 (Hyper-V)'

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
        Connect-AutomationPlatform -Platform 'HyperV' | Out-Null


        foreach ($hv in $ComputerName) {
            $hvArgs = @{ ComputerName = $hv; ErrorAction = 'Stop' }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $hv -Message 'Collecting host health'

            $vmHost = Get-VMHost @hvArgs
            $vms    = @(Get-VM @hvArgs)
            $running = @($vms | Where-Object { $_.State -eq 'Running' })

            $cim = @{ ErrorAction = 'Stop' }
            if ($hv -ne $env:COMPUTERNAME) { $cim.ComputerName = $hv }
            $os = Get-CimInstance -ClassName Win32_OperatingSystem @cim
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem @cim

            $assignedVCpu = ($running | Measure-Object -Property ProcessorCount -Sum).Sum
            if (-not $assignedVCpu) { $assignedVCpu = 0 }
            $ratio = if ($vmHost.LogicalProcessorCount -gt 0) {
                         [math]::Round($assignedVCpu / $vmHost.LogicalProcessorCount, 2)
                     } else { $null }

            $assignedMemGB = [math]::Round((($running | Measure-Object -Property MemoryAssigned -Sum).Sum) / 1GB, 2)
            $totalMemGB    = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)

            $drive = Split-Path -Qualifier $vmHost.VirtualHardDiskPath
            $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$drive'" @cim
            $freePct = if ($disk -and $disk.Size -gt 0) { [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1) } else { $null }

            $switches = @(Get-VMSwitch @hvArgs)

            $issues = @()
            if ($null -ne $freePct -and $freePct -lt $MinimumFreeDiskPercent) { $issues += "VHD store {0}% free" -f $freePct }
            if ($null -ne $ratio -and $ratio -gt $MaxCpuOvercommitRatio)      { $issues += "vCPU overcommit {0}:1" -f $ratio }
            if ($assignedMemGB -gt ($totalMemGB * 0.9))                        { $issues += 'assigned memory above 90% of physical' }

            $results.Add([PSCustomObject]@{
                Name              = $hv
                Id                = $hv
                LogicalProcessors = $vmHost.LogicalProcessorCount
                AssignedVCpu      = $assignedVCpu
                CpuOvercommit     = $ratio
                TotalMemoryGB     = $totalMemGB
                AssignedMemoryGB  = $assignedMemGB
                FreeMemoryGB      = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 2)
                VhdPath           = $vmHost.VirtualHardDiskPath
                VhdFreePercent    = $freePct
                VMsTotal          = $vms.Count
                VMsRunning        = $running.Count
                VirtualSwitches   = ($switches.Name -join '; ')
                UptimeDays        = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
                Status            = if ($issues.Count) { 'Warning' } else { 'OK' }
                Issues            = ($issues -join '; ')
            })
            if ($issues.Count) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $hv -Message ($issues -join '; ')
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Hyper-V Host Health Check'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
