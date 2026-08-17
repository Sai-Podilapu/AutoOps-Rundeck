<#
.SYNOPSIS
    Creates snapshots of Azure managed disks.

.DESCRIPTION
    Snapshots the OS disk, and optionally the data disks, of selected VMs.
    Additive and safe - a snapshot is an independent resource and changes
    nothing about the running VM. Named with the reason and a timestamp so the
    purpose stays readable later.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER SubscriptionId
    Subscription to operate in. Falls back to azure.defaultSubscriptionId in
    config.json.

.PARAMETER ResourceGroupName
    Limit to specific resource groups.

.PARAMETER VMName
    Virtual machines whose disks to snapshot.

.PARAMETER SnapshotReason
    Short reason recorded in the snapshot name and tags.

.PARAMETER IncludeDataDisks
    Also snapshot data disks, not just the OS disk.

.PARAMETER SnapshotSku
    Storage SKU for the snapshot. Standard_LRS is the cheapest and is usually
    right.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-AzDiskSnapshot.ps1 -VMName APP01 -SnapshotReason 'pre-patch'

    Snapshots the OS disk of APP01.

.EXAMPLE
    .\New-AzDiskSnapshot.ps1 -ResourceGroupName rg-prod -IncludeDataDisks -WhatIf

    Shows every disk that would be snapshotted.

.NOTES
    Source use case      : #3 - Azure Snapshot Creation
    Category             : Azure
    Technology           : Az PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Low
    Human approval needed: No
    Guardrails (col L)   : "Additive operation; safe"

    Required permissions : Disk Snapshot Contributor, or Contributor on the resource group.
    Required modules     : Az.Accounts, Az.Compute
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Snapshots bill for the storage they occupy for as long as they exist.
    Pair every snapshot created here with a retention plan, or
    Remove-AzDiskSnapshot.ps1 will find them months later.

    Rollback             : Delete the snapshot with Remove-AzDiskSnapshot.ps1.
                           It is an independent resource and removing it
                           affects nothing else.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Az.Compute

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$SubscriptionId,

    [string[]]$ResourceGroupName,

    [string[]]$VMName,

    [ValidateNotNullOrEmpty()]
    [string]$SnapshotReason = 'pre-change',

    [switch]$IncludeDataDisks,

    [ValidateSet('Standard_LRS','Standard_ZRS','Premium_LRS')]
    [string]$SnapshotSku = 'Standard_LRS',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-AzDiskSnapshot'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #3 (Azure)'

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
        if ($VMName) { $vms = $vms | Where-Object { $VMName -contains $_.Name } }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

        foreach ($vm in $vms) {
            $disks = @([PSCustomObject]@{ Name = $vm.StorageProfile.OsDisk.Name
                                          Id   = $vm.StorageProfile.OsDisk.ManagedDisk.Id
                                          Role = 'OS' })
            if ($IncludeDataDisks) {
                foreach ($d in $vm.StorageProfile.DataDisks) {
                    $disks += [PSCustomObject]@{ Name = $d.Name; Id = $d.ManagedDisk.Id; Role = "Data(lun $($d.Lun))" }
                }
            }

            foreach ($d in $disks) {
                if (-not $d.Id) { continue }        # unmanaged disks are out of scope
                $results.Add([PSCustomObject]@{
                    Name          = ('{0} / {1}' -f $vm.Name, $d.Name)
                    Id            = $d.Id
                    VMName        = $vm.Name
                    ResourceGroup = $vm.ResourceGroupName
                    Location      = $vm.Location
                    DiskName      = $d.Name
                    DiskRole      = $d.Role
                    SnapshotName  = ('{0}-{1}-{2}' -f $d.Name, $SnapshotReason, $stamp)
                    SnapshotSku   = $SnapshotSku
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Create disk snapshot')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            $cfg = New-AzSnapshotConfig -SourceUri $item.Id -Location $item.Location `
                -CreateOption Copy -SkuName $item.SnapshotSku `
                -Tag @{ CreatedBy = $scriptName; Reason = $SnapshotReason; SourceVM = $item.VMName }

            New-AzSnapshot -ResourceGroupName $item.ResourceGroup -SnapshotName $item.SnapshotName `
                -Snapshot $cfg -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Snapshot created: {0} ({1})' -f $item.SnapshotName, $item.DiskRole)
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Snapshot Creation'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
