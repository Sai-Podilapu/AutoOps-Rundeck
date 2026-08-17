<#
.SYNOPSIS
    Exports a full inventory of Hyper-V virtual machines.

.DESCRIPTION
    Produces a CPU, memory, disk and network inventory for every VM, including
    generation, checkpoint count, integration services state and the virtual
    switches each VM is attached to. Intended as the export that feeds a CMDB
    or a capacity review.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER ComputerName
    Hyper-V host(s) to act against. Defaults to the local host.

.PARAMETER VMName
    Limit to specific virtual machines. Wildcards are accepted for reporting
    scripts only.

.PARAMETER Credential
    Credential for the remote Hyper-V host.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-HvVmInventoryReport.ps1 -ComputerName HV01,HV02 -OutputFormat CSV

    Exports the estate inventory to CSV.

.EXAMPLE
    .\Get-HvVmInventoryReport.ps1 -ComputerName HV01 -VMName APP01 -OutputFormat JSON

    Exports one VM with full nested detail as JSON.

.NOTES
    Source use case      : #9 - Hyper-V VM Inventory Report
    Category             : Hyper-V
    Technology           : PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Export CPU/RAM/disk/network inventory"

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

    [string[]]$VMName,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-HvVmInventoryReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #9 (Hyper-V)'

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

            $vms = if ($VMName) { Get-VM -Name $VMName @hvArgs } else { Get-VM @hvArgs }
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $hv -Message (
                'Inventorying {0} VM(s)' -f @($vms).Count)

            foreach ($vm in $vms) {
                $disks = @(Get-VMHardDiskDrive -VMName $vm.Name @hvArgs -ErrorAction SilentlyContinue)
                $totalDiskGB = 0
                $diskDetail = @()
                foreach ($d in $disks) {
                    try {
                        $v = Get-VHD -Path $d.Path -ComputerName $hv -ErrorAction Stop
                        $totalDiskGB += [math]::Round($v.Size / 1GB, 2)
                        $diskDetail += [PSCustomObject]@{
                            Path = $d.Path; SizeGB = [math]::Round($v.Size / 1GB, 2)
                            UsedGB = [math]::Round($v.FileSize / 1GB, 2); Type = "$($v.VhdType)"
                        }
                    } catch {
                        # A pass-through or offline disk has no VHD metadata.
                        $diskDetail += [PSCustomObject]@{ Path = $d.Path; SizeGB = $null; UsedGB = $null; Type = 'unreadable' }
                    }
                }

                $nics = @(Get-VMNetworkAdapter -VMName $vm.Name @hvArgs -ErrorAction SilentlyContinue)
                $snapCount = @(Get-VMSnapshot -VMName $vm.Name @hvArgs -ErrorAction SilentlyContinue).Count

                $results.Add([PSCustomObject]@{
                    Name                = ('{0}\{1}' -f $hv, $vm.Name)
                    Id                  = $vm.Id
                    VMName              = $vm.Name
                    HyperVHost          = $hv
                    State               = "$($vm.State)"
                    Generation          = $vm.Generation
                    ProcessorCount      = $vm.ProcessorCount
                    MemoryStartupGB     = [math]::Round($vm.MemoryStartup / 1GB, 2)
                    MemoryAssignedGB    = [math]::Round($vm.MemoryAssigned / 1GB, 2)
                    DynamicMemory       = $vm.DynamicMemoryEnabled
                    TotalDiskGB         = $totalDiskGB
                    DiskCount           = $disks.Count
                    Disks               = $diskDetail
                    NicCount            = $nics.Count
                    Networks            = (($nics | ForEach-Object { '{0}@{1}' -f $_.Name, $_.SwitchName }) -join '; ')
                    IpAddresses         = (($nics.IPAddresses | Where-Object { $_ }) -join '; ')
                    CheckpointCount     = $snapCount
                    IntegrationServices = "$($vm.IntegrationServicesState)"
                    UptimeDays          = if ($vm.Uptime) { [math]::Round($vm.Uptime.TotalDays, 1) } else { 0 }
                    CreatedAt           = $vm.CreationTime
                    Notes               = $vm.Notes
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Hyper-V VM Inventory Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
