<#
.SYNOPSIS
    Creates vSphere VM snapshots with a datastore free-space check.

.DESCRIPTION
    Takes a snapshot of each selected VM after verifying the datastore has
    room. The datastore check is the guardrail this use case names: a snapshot
    grows as the VM writes, and a full datastore stuns every VM on it, not
    just the one being snapshotted.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER VIServer
    vCenter server to connect to. Falls back to vmware.vCenterServer in
    config.json.

.PARAMETER Credential
    Credential for vCenter. Omit to use the PowerCLI credential store or SSPI.

.PARAMETER VMName
    Limit to specific virtual machines.

.PARAMETER ClusterName
    Limit to VMs or hosts in specific clusters.

.PARAMETER SnapshotReason
    Short reason recorded in the snapshot name.

.PARAMETER IncludeMemory
    Capture VM memory state. Slower and larger; off by default.

.PARAMETER Quiesce
    Quiesce the guest filesystem via VMware Tools for an
    application-consistent snapshot.

.PARAMETER MinimumDatastoreFreePercent
    Refuse to snapshot a VM whose datastore is below this free percentage.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-VmwareVmSnapshot.ps1 -VIServer vcenter01 -VMName APP01,APP02 -SnapshotReason 'pre-patch'

    Snapshots two VMs after checking their datastores.

.EXAMPLE
    .\New-VmwareVmSnapshot.ps1 -VIServer vcenter01 -ClusterName PROD -WhatIf

    Shows what would be snapshotted across a cluster.

.NOTES
    Source use case      : #1 - Create VM Snapshot
    Category             : VMware OnPrem
    Technology           : PowerCLI / REST API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Additive; datastore-space check in SOP"

    Required permissions : vSphere role with Virtual machine > Snapshot management > Create snapshot.
    Required modules     : VMware.VimAutomation.Core
    Authentication       : Connect-VIServer with the PowerCLI credential store
                           or an explicit -Credential.

    A snapshot is not a backup. It grows for as long as it exists and
    degrades VM disk performance. Pair every snapshot created here with a
    removal plan.

    Rollback             : Remove the snapshot with
                           Remove-VmwareVmSnapshot.ps1. The snapshot itself
                           changes nothing about the running VM.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$VIServer,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [string[]]$VMName,

    [string[]]$ClusterName,

    [ValidateNotNullOrEmpty()]
    [string]$SnapshotReason = 'pre-change',

    [switch]$IncludeMemory,

    [switch]$Quiesce,

    [ValidateRange(1,99)]
    [int]$MinimumDatastoreFreePercent = 15,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-VmwareVmSnapshot'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #1 (VMware OnPrem)'

    try {
        $config = if ($ConfigPath) { Get-AutomationConfig -Path $ConfigPath } else { Get-AutomationConfig }
        # Recorded so an audit can tell which environment a run targeted.
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Configuration loaded for environment: {0}' -f $config.environment)
    } catch {
        # Fail closed. Safety lists and endpoints live in config; acting
        # without them would bypass the guardrails this use case requires.
        throw ('Cannot read configuration, refusing to proceed: {0}' -f $_.Exception.Message)
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
            # Datastore headroom check - the guardrail for this row.
            $blocked = $false
            foreach ($ds in (Get-Datastore -VM $vm)) {
                $freePct = if ($ds.CapacityGB -gt 0) { [math]::Round(($ds.FreeSpaceGB / $ds.CapacityGB) * 100, 1) } else { 0 }
                if ($freePct -lt $MinimumDatastoreFreePercent) {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.Name -Message (
                        'Skipped - datastore {0} is {1}% free, below the {2}% floor' -f $ds.Name, $freePct, $MinimumDatastoreFreePercent)
                    $blocked = $true
                    break
                }
            }
            if ($blocked) { continue }

            $results.Add([PSCustomObject]@{
                Name         = $vm.Name
                Id           = $vm.Id
                VMName       = $vm.Name
                PowerState   = "$($vm.PowerState)"
                UsedSpaceGB  = [math]::Round($vm.UsedSpaceGB, 2)
                Datastores   = ((Get-Datastore -VM $vm).Name -join '; ')
                SnapshotName = ('{0}-{1}-{2}' -f $vm.Name, $SnapshotReason, (Get-Date -Format 'yyyyMMdd-HHmmss'))
                ExistingSnapshots = @(Get-Snapshot -VM $vm -ErrorAction SilentlyContinue).Count
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

    if ($candidates.Count -eq 0) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'No eligible objects. Nothing to do.'
        Write-Output @()
        return
    }

    # Every candidate is logged individually BEFORE any action is taken.
    foreach ($c in $candidates) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}' -f $c.Name) -Message 'CANDIDATE'
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Create VM snapshot')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $snapParams = @{
                VM          = $item.VMName
                Name        = $item.SnapshotName
                Description = ('Created by {0} on {1}' -f $scriptName, (Get-Date -Format 'yyyy-MM-dd HH:mm'))
                Confirm     = $false
                ErrorAction = 'Stop'
            }
            if ($IncludeMemory) { $snapParams.Memory = $true }
            if ($Quiesce)       { $snapParams.Quiesce = $true }

            New-Snapshot @snapParams | Out-Null
            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Snapshot created: {0} (memory={1} quiesce={2})' -f $item.SnapshotName, [bool]$IncludeMemory, [bool]$Quiesce)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'SnapshotCreated'; Detail = $item.SnapshotName; Succeeded = $true })
        } catch {
            $msg = $_.Exception.Message
            Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label -Message ('FAILED: {0}' -f $msg)
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Failed'; Detail = $msg; Succeeded = $false })
        }
    }

    $ok  = @($actions | Where-Object { $_.Succeeded })
    $bad = @($actions | Where-Object { -not $_.Succeeded })
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'END. Succeeded={0} Failed={1}' -f $ok.Count, $bad.Count)

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Create VM Snapshot'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
