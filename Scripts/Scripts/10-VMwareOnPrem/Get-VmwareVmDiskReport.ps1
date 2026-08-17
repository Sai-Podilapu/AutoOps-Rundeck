<#
.SYNOPSIS
    Reports virtual disk detail for vSphere virtual machines.

.DESCRIPTION
    Lists every virtual disk with its provisioning type, capacity, datastore
    and the guest partition free space where VMware Tools reports it.
    Thin-provisioned disks are called out separately, because a datastore can
    be oversubscribed without any single VM looking large.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER VIServer
    vCenter server to connect to. Falls back to vmware.vCenterServer in
    config.json.

.PARAMETER Credential
    Credential for vCenter. Omit to use the PowerCLI credential store or SSPI.

.PARAMETER VMName
    Limit to specific virtual machines.

.PARAMETER ClusterName
    Limit to VMs or hosts in specific clusters.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-VmwareVmDiskReport.ps1 -VIServer vcenter01 -OutputFormat CSV

    Exports the disk inventory to CSV.

.EXAMPLE
    .\Get-VmwareVmDiskReport.ps1 -VIServer vcenter01 -VMName APP01 -OutputFormat JSON

    Full nested disk detail for one VM as JSON.

.NOTES
    Source use case      : #6 - VM Disk Detail Report
    Category             : VMware OnPrem
    Technology           : PowerCLI
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only"

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

    [string[]]$VMName,

    [string[]]$ClusterName,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-VmwareVmDiskReport'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #6 (VMware OnPrem)'

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

        $vms = if ($VMName)          { Get-VM -Name $VMName -ErrorAction Stop }
               elseif ($ClusterName) { Get-Cluster -Name $ClusterName | Get-VM }
               else                  { Get-VM }

        foreach ($vm in $vms) {
            $guestDisks = @()
            if ($vm.PowerState -eq 'PoweredOn' -and $vm.ExtensionData.Guest.Disk) {
                $guestDisks = $vm.ExtensionData.Guest.Disk | ForEach-Object {
                    [PSCustomObject]@{
                        Path       = $_.DiskPath
                        CapacityGB = [math]::Round($_.Capacity / 1GB, 2)
                        FreeGB     = [math]::Round($_.FreeSpace / 1GB, 2)
                        FreePercent= if ($_.Capacity -gt 0) { [math]::Round(($_.FreeSpace / $_.Capacity) * 100, 1) } else { $null }
                    }
                }
            }

            foreach ($hd in (Get-HardDisk -VM $vm)) {
                $results.Add([PSCustomObject]@{
                    Name            = ('{0} / {1}' -f $vm.Name, $hd.Name)
                    Id              = $hd.Id
                    VMName          = $vm.Name
                    PowerState      = "$($vm.PowerState)"
                    DiskName        = $hd.Name
                    CapacityGB      = [math]::Round($hd.CapacityGB, 2)
                    StorageFormat   = "$($hd.StorageFormat)"
                    DiskType        = "$($hd.DiskType)"
                    Datastore       = ($hd.Filename -replace '^\[(.+?)\].*$', '$1')
                    Filename        = $hd.Filename
                    Persistence     = "$($hd.Persistence)"
                    GuestVolumes    = $guestDisks
                    ThinProvisioned = ("$($hd.StorageFormat)" -eq 'Thin')
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'VM Disk Detail Report'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
