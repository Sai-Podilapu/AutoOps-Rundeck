<#
.SYNOPSIS
    Exports an inventory of Azure virtual machines.

.DESCRIPTION
    Lists every VM with size, OS, power state, disks, network interfaces,
    private and public IP addresses, availability configuration and tags. The
    export a CMDB or a cost review actually needs, rather than just names.

    This script is READ-ONLY. It issues no write, modify or delete call and
    is safe to schedule unattended.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER IncludeNetworkDetail
    Resolve NIC and IP detail. Adds an API call per VM, so it is optional on
    large estates.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Get-AzVmInventory.ps1 -OutputFormat CSV

    Exports the whole subscription to CSV.

.EXAMPLE
    .\Get-AzVmInventory.ps1 -ResourceGroupName rg-prod -IncludeNetworkDetail -OutputFormat JSON

    Full detail including IPs for one resource group.

.NOTES
    Source use case      : #2 - Azure List of VMs
    Category             : Azure
    Technology           : Az CLI / PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Read / Report
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Read-only inventory"

    Required permissions : Reader on the target scope.
    Required modules     : Az.Accounts, Az.Compute, Az.Network
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Rollback             : Not applicable - this script makes no change.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Compute
#Requires -Modules Az.Network

[CmdletBinding()]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [switch]$IncludeNetworkDetail,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Get-AzVmInventory'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #2 (Azure)'

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

        foreach ($vm in $vms) {
            $status = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status
            $power  = ($status.Statuses | Where-Object Code -like 'PowerState/*' |
                       Select-Object -First 1 -Expand DisplayStatus)

            $privateIps = @(); $publicIps = @()
            if ($IncludeNetworkDetail) {
                foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
                    try {
                        $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id -ErrorAction Stop
                        $privateIps += $nic.IpConfigurations.PrivateIpAddress
                        foreach ($cfg in $nic.IpConfigurations) {
                            if ($cfg.PublicIpAddress) {
                                $pip = Get-AzPublicIpAddress -ResourceId $cfg.PublicIpAddress.Id -ErrorAction SilentlyContinue
                                if ($pip) { $publicIps += $pip.IpAddress }
                            }
                        }
                    } catch {
                        Write-Verbose ('NIC detail unavailable for {0}' -f $vm.Name)
                    }
                }
            }

            $dataDisks = @($vm.StorageProfile.DataDisks | ForEach-Object {
                [PSCustomObject]@{ Name = $_.Name; SizeGB = $_.DiskSizeGB; Lun = $_.Lun; Caching = "$($_.Caching)" }
            })

            $results.Add([PSCustomObject]@{
                Name            = $vm.Name
                Id              = $vm.Id
                ResourceGroup   = $vm.ResourceGroupName
                Location        = $vm.Location
                VmSize          = $vm.HardwareProfile.VmSize
                PowerState      = $power
                OsType          = "$($vm.StorageProfile.OsDisk.OsType)"
                OsDiskSizeGB    = $vm.StorageProfile.OsDisk.DiskSizeGB
                OsDiskType      = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
                DataDiskCount   = $dataDisks.Count
                DataDisks       = $dataDisks
                PrivateIps      = ($privateIps -join '; ')
                PublicIps       = ($publicIps -join '; ')
                AvailabilitySet = if ($vm.AvailabilitySetReference) { ($vm.AvailabilitySetReference.Id -split '/')[-1] } else { $null }
                Zones           = ($vm.Zones -join ',')
                LicenseType     = $vm.LicenseType
                Tags            = (($vm.Tags.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')
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
    $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure List of VMs'
    Write-Output $candidates
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Message 'END'
    if ($failures.Count -gt 0 -and $candidates.Count -eq 0) { exit 1 }
}
