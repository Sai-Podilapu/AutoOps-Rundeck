# -*- coding: utf-8 -*-
"""VMware OnPrem - 13 use cases. Real VMware PowerCLI cmdlets."""

VC = dict(name='VIServer', help='vCenter server to connect to. Falls back to vmware.vCenterServer in config.json.',
          decl="[string]$VIServer")
CRED = dict(name='Credential', help='Credential for vCenter. Omit to use the PowerCLI credential store or SSPI.',
            decl="[System.Management.Automation.PSCredential]\n    [System.Management.Automation.Credential()]\n    $Credential = [System.Management.Automation.PSCredential]::Empty")
VM = dict(name='VMName', help='Limit to specific virtual machines.',
          decl="[string[]]$VMName")
CLUSTER = dict(name='ClusterName', help='Limit to VMs or hosts in specific clusters.',
               decl="[string[]]$ClusterName")

# Every VMware script opens its own connection, because PowerCLI holds the
# session in $global:DefaultVIServers rather than passing it per call.
CONNECT = """
if (-not $VIServer -and $config -and $config.vmware) { $VIServer = $config.vmware.vCenterServer }
if (-not $VIServer) { throw 'No vCenter specified. Pass -VIServer or set vmware.vCenterServer in config.json.' }

$viParams = @{ Server = $VIServer; ErrorAction = 'Stop' }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $viParams.Credential = $Credential }
$vc = Connect-VIServer @viParams
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $VIServer -Message (
    'Connected to vCenter {0} (version {1})' -f $vc.Name, $vc.Version)
"""

SPECS = {

1: dict(
    file='New-VmwareVmSnapshot',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Creates vSphere VM snapshots with a datastore free-space check.',
    desc='Takes a snapshot of each selected VM after verifying the datastore has room. The '
         'datastore check is the guardrail this use case names: a snapshot grows as the VM writes, '
         'and a full datastore stuns every VM on it, not just the one being snapshotted.',
    params=[VC, CRED, VM, CLUSTER,
            dict(name='SnapshotReason', help='Short reason recorded in the snapshot name.',
                 decl="[ValidateNotNullOrEmpty()]\n    [string]$SnapshotReason = 'pre-change'"),
            dict(name='IncludeMemory', help='Capture VM memory state. Slower and larger; off by default.',
                 decl="[switch]$IncludeMemory"),
            dict(name='Quiesce', help='Quiesce the guest filesystem via VMware Tools for an application-consistent snapshot.',
                 decl="[switch]$Quiesce"),
            dict(name='MinimumDatastoreFreePercent', help='Refuse to snapshot a VM whose datastore is below this free percentage.',
                 decl="[ValidateRange(1,99)]\n    [int]$MinimumDatastoreFreePercent = 15")],
    perms='vSphere role with Virtual machine > Snapshot management > Create snapshot.',
    actionVerb='Create VM snapshot',
    rollback='Remove the snapshot with Remove-VmwareVmSnapshot.ps1. The snapshot itself changes '
             'nothing about the running VM.',
    notes='A snapshot is not a backup. It grows for as long as it exists and degrades VM disk '
          'performance. Pair every snapshot created here with a removal plan.',
    examples=[("-VIServer vcenter01 -VMName APP01,APP02 -SnapshotReason 'pre-patch'",
               'Snapshots two VMs after checking their datastores.'),
              ("-VIServer vcenter01 -ClusterName PROD -WhatIf",
               'Shows what would be snapshotted across a cluster.')],
    discover=CONNECT + """
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
""",
    act="""
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
"""),

2: dict(
    file='Remove-VmwareVmSnapshot',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Removes vSphere snapshots older than a minimum age.',
    desc='Deletes snapshots beyond the retention age, optionally filtered by name pattern. Age and '
         'name filters are the safety control the workbook names: they stop the script touching a '
         'snapshot taken minutes ago for a change still in flight.',
    params=[VC, CRED, VM, CLUSTER,
            dict(name='MinimumAgeDays', help='Only remove snapshots older than this.',
                 decl="[ValidateRange(1,3650)]\n    [int]$MinimumAgeDays = 7"),
            dict(name='NamePattern', help='Only remove snapshots whose name matches this wildcard pattern. Restricts the blast radius further.',
                 decl="[string]$NamePattern = '*'"),
            dict(name='KeepLatest', help='Always keep this many of the newest snapshots per VM regardless of age.',
                 decl="[ValidateRange(0,50)]\n    [int]$KeepLatest = 0")],
    perms='vSphere role with Virtual machine > Snapshot management > Remove snapshot.',
    actionVerb='Remove VM snapshot',
    rollback='NONE. Removing a snapshot consolidates its delta into the base disk and cannot be '
             'undone. The age and name filters exist because there is no recovery.',
    notes='Consolidation generates heavy datastore IO and can briefly stun the VM. Schedule outside '
          'peak hours - the consolidation impact is why the workbook rates this Medium rather than Low.',
    examples=[("-VIServer vcenter01 -MinimumAgeDays 7",
               'Removes snapshots older than a week.'),
              ("-VIServer vcenter01 -NamePattern 'pre-patch*' -MinimumAgeDays 14 -WhatIf",
               'Shows which old patching snapshots would be consolidated.')],
    discover=CONNECT + """
$vms = if ($VMName)          { Get-VM -Name $VMName -ErrorAction Stop }
       elseif ($ClusterName) { Get-Cluster -Name $ClusterName | Get-VM }
       else                  { Get-VM }

$cutoff = (Get-Date).AddDays(-$MinimumAgeDays)

foreach ($vm in $vms) {
    $snaps = @(Get-Snapshot -VM $vm -ErrorAction SilentlyContinue | Sort-Object Created -Descending)
    if ($snaps.Count -eq 0) { continue }

    $eligible = if ($KeepLatest -gt 0) { $snaps | Select-Object -Skip $KeepLatest } else { $snaps }

    foreach ($s in $eligible) {
        if ($s.Created -ge $cutoff) { continue }
        if ($s.Name -notlike $NamePattern) { continue }

        $results.Add([PSCustomObject]@{
            Name         = ('{0} / {1}' -f $vm.Name, $s.Name)
            Id           = $s.Id
            VMName       = $vm.Name
            SnapshotName = $s.Name
            CreatedAt    = $s.Created
            AgeDays      = [math]::Round(((Get-Date) - $s.Created).TotalDays, 1)
            SizeGB       = [math]::Round($s.SizeGB, 2)
            Description  = $s.Description
            ConsolidationNote = 'delta merges into the base disk on removal'
        })
    }
}
""",
    act="""
$snap = Get-Snapshot -VM $item.VMName -Name $item.SnapshotName -ErrorAction Stop
Remove-Snapshot -Snapshot $snap -Confirm:$false -ErrorAction Stop
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Snapshot removed (age {0}d, {1}GB). Consolidation now in progress on the datastore.' -f $item.AgeDays, $item.SizeGB)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'SnapshotRemoved'; Detail = ('age {0}d, {1}GB' -f $item.AgeDays, $item.SizeGB); Succeeded = $true })
"""),

3: dict(
    file='New-VmwareVirtualMachine',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Provisions a vSphere virtual machine from an approved specification.',
    desc='Creates a VM from a template or as an empty shell with the requested CPU, memory and '
         'disk, after verifying the target cluster and datastore have capacity. The capacity check '
         'is the guardrail: the cost of a provisioning mistake here is paid by every workload '
         'sharing the datastore.',
    params=[VC, CRED,
            dict(name='NewVMName', help='Name of the VM to create.',
                 decl="[Parameter(Mandatory)]\n    [ValidateNotNullOrEmpty()]\n    [string]$NewVMName"),
            dict(name='TargetCluster', help='Cluster to place the VM in.',
                 decl="[Parameter(Mandatory)]\n    [string]$TargetCluster"),
            dict(name='Datastore', help='Datastore or datastore cluster for the VM.',
                 decl="[Parameter(Mandatory)]\n    [string]$Datastore"),
            dict(name='Template', help='Template to deploy from. Omit to create an empty VM.',
                 decl="[string]$Template"),
            dict(name='NumCpu', help='Virtual CPU count.',
                 decl="[ValidateRange(1,128)]\n    [int]$NumCpu = 2"),
            dict(name='MemoryGB', help='Memory in GB.',
                 decl="[ValidateRange(1,6144)]\n    [int]$MemoryGB = 4"),
            dict(name='DiskGB', help='System disk size in GB.',
                 decl="[ValidateRange(1,62000)]\n    [int]$DiskGB = 60"),
            dict(name='PortGroup', help='Network port group to attach.',
                 decl="[string]$PortGroup"),
            dict(name='MinimumDatastoreFreePercent', help='Refuse to provision if the datastore would drop below this.',
                 decl="[ValidateRange(1,99)]\n    [int]$MinimumDatastoreFreePercent = 20")],
    perms='vSphere role with Virtual machine > Inventory > Create new, plus datastore allocate space.',
    actionVerb='Provision vSphere VM',
    reason='New VM provisioning',
    rollback='Remove-VM. The VM is created powered off, so a mistaken provision consumes storage '
             'but affects no running workload.',
    examples=[("-VIServer vcenter01 -NewVMName APP03 -TargetCluster PROD -Datastore DS-PROD-01 -Template W2022-STD",
               'REQUEST mode - validates capacity and raises an approval, creating nothing.'),
              ("-VIServer vcenter01 -NewVMName APP03 -TargetCluster PROD -Datastore DS-PROD-01 -ApprovalReference APR-...",
               'Creates the VM after the specification has been approved.')],
    discover=CONNECT + """
if (Get-VM -Name $NewVMName -ErrorAction SilentlyContinue) {
    throw ('A VM named {0} already exists in {1}. Refusing to provision a duplicate.' -f $NewVMName, $VIServer)
}

$cluster = Get-Cluster -Name $TargetCluster -ErrorAction Stop
$ds      = Get-Datastore -Name $Datastore -ErrorAction Stop

$freeAfterGB  = $ds.FreeSpaceGB - $DiskGB
$freeAfterPct = if ($ds.CapacityGB -gt 0) { [math]::Round(($freeAfterGB / $ds.CapacityGB) * 100, 1) } else { 0 }
if ($freeAfterPct -lt $MinimumDatastoreFreePercent) {
    throw ('Refusing to provision: datastore {0} would be {1}% free after a {2}GB disk, below the {3}% floor.' -f
           $ds.Name, $freeAfterPct, $DiskGB, $MinimumDatastoreFreePercent)
}

# Cluster CPU/memory headroom, so an approver sees the capacity impact.
$hosts = @(Get-VMHost -Location $cluster)
$totalMemGB = [math]::Round((($hosts | Measure-Object MemoryTotalGB -Sum).Sum), 1)
$usedMemGB  = [math]::Round((($hosts | Measure-Object MemoryUsageGB -Sum).Sum), 1)

$results.Add([PSCustomObject]@{
    Name              = $NewVMName
    Id                = $NewVMName
    VMName            = $NewVMName
    Cluster           = $cluster.Name
    Datastore         = $ds.Name
    Template          = $Template
    NumCpu            = $NumCpu
    MemoryGB          = $MemoryGB
    DiskGB            = $DiskGB
    PortGroup         = $PortGroup
    DatastoreFreeGB   = [math]::Round($ds.FreeSpaceGB, 1)
    DatastoreFreeAfterPct = $freeAfterPct
    ClusterMemoryTotalGB  = $totalMemGB
    ClusterMemoryUsedGB   = $usedMemGB
    ClusterHosts      = $hosts.Count
})
""",
    act="""
$newParams = @{
    Name        = $item.VMName
    ResourcePool= (Get-Cluster -Name $item.Cluster)
    Datastore   = (Get-Datastore -Name $item.Datastore)
    Confirm     = $false
    ErrorAction = 'Stop'
}
if ($item.Template) {
    $newParams.Template = (Get-Template -Name $item.Template -ErrorAction Stop)
} else {
    $newParams.NumCpu    = $item.NumCpu
    $newParams.MemoryGB  = $item.MemoryGB
    $newParams.DiskGB    = $item.DiskGB
    $newParams.GuestId   = 'windows2019srvNext_64Guest'
}
if ($item.PortGroup) { $newParams.PortGroup = (Get-VirtualPortGroup -Name $item.PortGroup -ErrorAction Stop) }

$created = New-VM @newParams

# A template deployment inherits the template's spec, so the requested CPU and
# memory are applied afterwards rather than assumed.
if ($item.Template) {
    Set-VM -VM $created -NumCpu $item.NumCpu -MemoryGB $item.MemoryGB -Confirm:$false -ErrorAction Stop | Out-Null
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'VM provisioned: {0} vCPU, {1}GB RAM, {2}GB disk on {3}. Left powered OFF for build.' -f
    $item.NumCpu, $item.MemoryGB, $item.DiskGB, $item.Datastore)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Provisioned'; Detail = ('cluster {0}' -f $item.Cluster); Succeeded = $true })
"""),

4: dict(
    file='Update-VmwareTools',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Upgrades VMware Tools on virtual machines.',
    desc='Upgrades VMware Tools where the current version is out of date. A Tools upgrade can '
         'require a guest reboot and briefly drops the network adapter, which is why the workbook '
         'gates it on approval and a maintenance window. -NoReboot is passed by default so the '
         'guest is not restarted without a separate decision.',
    params=[VC, CRED, VM, CLUSTER,
            dict(name='AllowReboot', help='Permit the guest to reboot if the Tools upgrade requires it. Off by default.',
                 decl="[switch]$AllowReboot"),
            dict(name='IncludePoweredOff', help='Include powered-off VMs in the candidate list. They cannot be upgraded in place, so they are excluded by default.',
                 decl="[switch]$IncludePoweredOff")],
    perms='vSphere role with Virtual machine > Interaction > VMware Tools install.',
    actionVerb='Upgrade VMware Tools',
    reason='VMware Tools upgrade',
    rollback='NONE in place - Tools cannot be downgraded through this path. Snapshot the VM first '
             'with New-VmwareVmSnapshot.ps1 if you need a way back.',
    notes='The upgrade briefly disconnects the guest network adapter as the vmxnet driver reloads. '
          'On a VM reached only over that adapter, expect a short loss of session even without a reboot.',
    examples=[("-VIServer vcenter01 -ClusterName PROD",
               'REQUEST mode - lists VMs with outdated Tools and raises an approval.'),
              ("-VIServer vcenter01 -VMName APP01 -ApprovalReference APR-... -AllowReboot",
               'Upgrades Tools on APP01, permitting a reboot if required.')],
    discover=CONNECT + """
$vms = if ($VMName)          { Get-VM -Name $VMName -ErrorAction Stop }
       elseif ($ClusterName) { Get-Cluster -Name $ClusterName | Get-VM }
       else                  { Get-VM }

foreach ($vm in $vms) {
    if (-not $IncludePoweredOff -and $vm.PowerState -ne 'PoweredOn') { continue }

    $tools = $vm.ExtensionData.Guest.ToolsStatus
    $ver   = $vm.ExtensionData.Guest.ToolsVersion

    # toolsOk means current. Anything else is either old, absent or not running.
    if ($tools -eq 'toolsOk') { continue }
    if ($tools -eq 'toolsNotInstalled') {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.Name `
            -Message 'Skipped - VMware Tools is not installed; an upgrade cannot install it'
        continue
    }

    $results.Add([PSCustomObject]@{
        Name          = $vm.Name
        Id            = $vm.Id
        VMName        = $vm.Name
        PowerState    = "$($vm.PowerState)"
        ToolsStatus   = "$tools"
        ToolsVersion  = $ver
        GuestOS       = $vm.ExtensionData.Guest.GuestFullName
        RebootMayBeRequired = $true
    })
}
""",
    act="""
$vmObj = Get-VM -Name $item.VMName -ErrorAction Stop
$upParams = @{ VM = $vmObj; Confirm = $false; ErrorAction = 'Stop' }
if (-not $AllowReboot) { $upParams.NoReboot = $true }

Update-Tools @upParams

# Re-read rather than trusting the cmdlet's return.
$after = (Get-VM -Name $item.VMName).ExtensionData.Guest.ToolsStatus
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Tools upgrade issued (reboot allowed={0}). Status now: {1}' -f [bool]$AllowReboot, $after)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'ToolsUpgraded'
    Detail = ('{0} -> {1}' -f $item.ToolsStatus, $after); Succeeded = $true })
"""),

5: dict(
    file='Get-VmwareHealthReport',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Reports vSphere host, cluster and datastore health.',
    desc='Collects the health signals that matter on a vSphere estate: host connection and '
         'maintenance state, CPU and memory headroom per cluster, datastore free space, HA and DRS '
         'configuration, and triggered vCenter alarms. Reports HA admission-control headroom, '
         'because a cluster that is healthy today but cannot absorb a host failure is the situation '
         'this catches.',
    params=[VC, CRED, CLUSTER,
            dict(name='MinimumDatastoreFreePercent', help='Flag datastores below this free percentage.',
                 decl="[ValidateRange(1,99)]\n    [int]$MinimumDatastoreFreePercent = 15"),
            dict(name='MaxMemoryUsagePercent', help='Flag hosts above this memory usage.',
                 decl="[ValidateRange(1,100)]\n    [int]$MaxMemoryUsagePercent = 85")],
    perms='vSphere read-only role.',
    examples=[("-VIServer vcenter01 -OutputFormat HTML",
               'Full estate health report as HTML.'),
              ("-VIServer vcenter01 -ClusterName PROD -MinimumDatastoreFreePercent 25",
               'Checks one cluster with a tighter datastore threshold.')],
    discover=CONNECT + """
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
"""),

6: dict(
    file='Get-VmwareVmDiskReport',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Reports virtual disk detail for vSphere virtual machines.',
    desc='Lists every virtual disk with its provisioning type, capacity, datastore and the guest '
         'partition free space where VMware Tools reports it. Thin-provisioned disks are called out '
         'separately, because a datastore can be oversubscribed without any single VM looking large.',
    params=[VC, CRED, VM, CLUSTER],
    perms='vSphere read-only role.',
    examples=[("-VIServer vcenter01 -OutputFormat CSV",
               'Exports the disk inventory to CSV.'),
              ("-VIServer vcenter01 -VMName APP01 -OutputFormat JSON",
               'Full nested disk detail for one VM as JSON.')],
    discover=CONNECT + """
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
            Datastore       = ($hd.Filename -replace '^\\[(.+?)\\].*$', '$1')
            Filename        = $hd.Filename
            Persistence     = "$($hd.Persistence)"
            GuestVolumes    = $guestDisks
            ThinProvisioned = ("$($hd.StorageFormat)" -eq 'Thin')
        })
    }
}
"""),

7: dict(
    file='Start-VmwareVirtualMachine',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Powers on vSphere virtual machines.',
    desc='Powers on selected VMs and waits for VMware Tools to report running, so the result '
         'reflects a booted guest rather than only a started VM. Reversible and low risk, so it '
         'executes directly - but it still logs every VM it touched.',
    params=[VC, CRED, VM, CLUSTER,
            dict(name='WaitForToolsSeconds', help='How long to wait for VMware Tools to report running. 0 skips the wait.',
                 decl="[ValidateRange(0,3600)]\n    [int]$WaitForToolsSeconds = 300")],
    perms='vSphere role with Virtual machine > Interaction > Power on.',
    actionVerb='Power on VM',
    rollback='Power the VM off again with Stop-VmwareVirtualMachine.ps1.',
    examples=[("-VIServer vcenter01 -VMName APP01,APP02",
               'Powers on two VMs and waits for Tools.'),
              ("-VIServer vcenter01 -VMName APP01 -WaitForToolsSeconds 0",
               'Issues the power-on without waiting for the guest.')],
    discover=CONNECT + """
$vms = if ($VMName)          { Get-VM -Name $VMName -ErrorAction Stop }
       elseif ($ClusterName) { Get-Cluster -Name $ClusterName | Get-VM }
       else                  { throw 'Specify -VMName or -ClusterName. Powering on every VM in vCenter is not a safe default.' }

foreach ($vm in $vms) {
    if ($vm.PowerState -eq 'PoweredOn') {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $vm.Name -Message 'Skipped - already powered on'
        continue
    }
    $results.Add([PSCustomObject]@{
        Name       = $vm.Name
        Id         = $vm.Id
        VMName     = $vm.Name
        PowerState = "$($vm.PowerState)"
        VMHost     = $vm.VMHost.Name
        NumCpu     = $vm.NumCpu
        MemoryGB   = $vm.MemoryGB
    })
}
""",
    act="""
Start-VM -VM $item.VMName -Confirm:$false -ErrorAction Stop | Out-Null

$toolsState = 'not waited for'
if ($WaitForToolsSeconds -gt 0) {
    $deadline = (Get-Date).AddSeconds($WaitForToolsSeconds)
    do {
        Start-Sleep -Seconds 5
        $toolsState = (Get-VM -Name $item.VMName).ExtensionData.Guest.ToolsRunningStatus
    } while ($toolsState -ne 'guestToolsRunning' -and (Get-Date) -lt $deadline)

    if ($toolsState -ne 'guestToolsRunning') {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
            'Powered on but VMware Tools did not report running within {0}s (state: {1})' -f $WaitForToolsSeconds, $toolsState)
    }
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Powered on. Tools state: {0}' -f $toolsState)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'PoweredOn'; Detail = ('tools: {0}' -f $toolsState); Succeeded = $true })
"""),

8: dict(
    file='Stop-VmwareVirtualMachine',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Powers off vSphere virtual machines, gracefully by default.',
    desc='Shuts down guests through VMware Tools and only falls back to a hard power-off when '
         '-Force is given and the graceful attempt has timed out. Powering off a production VM '
         'needs ticket confirmation, which is why this is approval-gated even though the operation '
         'itself is routine.',
    params=[VC, CRED, VM, CLUSTER,
            dict(name='Force', help='Permit a hard power-off if the graceful shutdown does not complete within the timeout.',
                 decl="[switch]$Force"),
            dict(name='ShutdownTimeoutSeconds', help='How long to wait for the guest to shut down gracefully.',
                 decl="[ValidateRange(10,3600)]\n    [int]$ShutdownTimeoutSeconds = 300")],
    perms='vSphere role with Virtual machine > Interaction > Power off and Shut down guest.',
    actionVerb='Power off VM',
    reason='Planned VM shutdown',
    rollback='Power the VM back on with Start-VmwareVirtualMachine.ps1. A hard power-off may leave '
             'the guest filesystem dirty, which is why it is never the first attempt.',
    examples=[("-VIServer vcenter01 -VMName APP01",
               'REQUEST mode - raises an approval to shut down APP01.'),
              ("-VIServer vcenter01 -VMName APP01 -ApprovalReference APR-... -Force",
               'Shuts down gracefully, falling back to a hard power-off if the guest does not respond.')],
    discover=CONNECT + """
$vms = if ($VMName)          { Get-VM -Name $VMName -ErrorAction Stop }
       elseif ($ClusterName) { Get-Cluster -Name $ClusterName | Get-VM }
       else                  { throw 'Specify -VMName or -ClusterName. Powering off every VM in vCenter is not a safe default.' }

foreach ($vm in $vms) {
    if ($vm.PowerState -eq 'PoweredOff') {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $vm.Name -Message 'Skipped - already powered off'
        continue
    }
    $toolsRunning = ($vm.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning')
    if (-not $toolsRunning -and -not $Force) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.Name `
            -Message 'VMware Tools is not running - a graceful shutdown is not possible. Pass -Force to allow a hard power-off.'
    }
    $results.Add([PSCustomObject]@{
        Name         = $vm.Name
        Id           = $vm.Id
        VMName       = $vm.Name
        PowerState   = "$($vm.PowerState)"
        VMHost       = $vm.VMHost.Name
        ToolsRunning = $toolsRunning
        GuestOS      = $vm.ExtensionData.Guest.GuestFullName
        Method       = if ($toolsRunning) { 'graceful guest shutdown' } elseif ($Force) { 'hard power off' } else { 'blocked - no Tools and no -Force' }
    })
}
""",
    act="""
$vmObj = Get-VM -Name $item.VMName -ErrorAction Stop

if ($item.ToolsRunning) {
    Stop-VMGuest -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null

    $deadline = (Get-Date).AddSeconds($ShutdownTimeoutSeconds)
    do {
        Start-Sleep -Seconds 5
        $state = (Get-VM -Name $item.VMName).PowerState
    } while ("$state" -ne 'PoweredOff' -and (Get-Date) -lt $deadline)

    if ("$state" -ne 'PoweredOff') {
        if ($Force) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                'Guest did not shut down within {0}s - falling back to a hard power-off as -Force was given' -f $ShutdownTimeoutSeconds)
            Stop-VM -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null
        } else {
            throw ('Guest did not shut down within {0}s and -Force was not given. VM left running.' -f $ShutdownTimeoutSeconds)
        }
    }
} else {
    if (-not $Force) {
        throw 'VMware Tools is not running and -Force was not given. Refusing a hard power-off by default.'
    }
    Stop-VM -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null
}

$final = (Get-VM -Name $item.VMName).PowerState
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Power off complete via {0}. State: {1}' -f $item.Method, $final)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'PoweredOff'; Detail = ('{0}; final state {1}' -f $item.Method, $final)
    Succeeded = ("$final" -eq 'PoweredOff') })
"""),

9: dict(
    file='Restart-VmwareVirtualMachine',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Restarts a vSphere virtual machine, guest-initiated by default.',
    desc='Restarts selected VMs. A guest restart through VMware Tools is attempted first; the hard '
         'reset - which is equivalent to pressing the reset button and risks filesystem damage - '
         'requires an explicit -HardReset. The workbook rates this Medium risk for exactly that '
         'reason and gates it on approval.',
    params=[VC, CRED, VM,
            dict(name='HardReset', help='Perform a hard reset instead of a guest restart. Risks data loss; never the default.',
                 decl="[switch]$HardReset"),
            dict(name='WaitForToolsSeconds', help='How long to wait for VMware Tools to come back after the restart.',
                 decl="[ValidateRange(0,3600)]\n    [int]$WaitForToolsSeconds = 300")],
    perms='vSphere role with Virtual machine > Interaction > Reset and Restart guest.',
    actionVerb='Restart VM',
    reason='Planned VM restart',
    rollback='NONE for a hard reset - an interrupted write is not recoverable. That is why the '
             'guest restart is the default and -HardReset must be chosen deliberately.',
    examples=[("-VIServer vcenter01 -VMName APP01",
               'REQUEST mode - raises an approval for a guest restart.'),
              ("-VIServer vcenter01 -VMName APP01 -ApprovalReference APR-... -HardReset",
               'Performs an approved hard reset.')],
    discover=CONNECT + """
if (-not $VMName) { throw 'Specify -VMName. Restarting every VM in vCenter is not a safe default.' }

foreach ($vm in (Get-VM -Name $VMName -ErrorAction Stop)) {
    if ($vm.PowerState -ne 'PoweredOn') {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.Name `
            -Message ('Skipped - VM is {0}, not PoweredOn' -f $vm.PowerState)
        continue
    }
    $toolsRunning = ($vm.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning')
    if (-not $toolsRunning -and -not $HardReset) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.Name `
            -Message 'VMware Tools is not running - a guest restart is not possible. -HardReset would be required.'
    }
    $results.Add([PSCustomObject]@{
        Name         = $vm.Name
        Id           = $vm.Id
        VMName       = $vm.Name
        PowerState   = "$($vm.PowerState)"
        ToolsRunning = $toolsRunning
        VMHost       = $vm.VMHost.Name
        Method       = if ($HardReset) { 'HARD RESET (risks data loss)' }
                       elseif ($toolsRunning) { 'guest restart' }
                       else { 'blocked - no Tools and no -HardReset' }
    })
}
""",
    act="""
$vmObj = Get-VM -Name $item.VMName -ErrorAction Stop

if ($HardReset) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
        'HARD RESET requested. Approval={0} Ticket={1}' -f $ApprovalReference, $TicketReference)
    Restart-VM -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null
} else {
    if (-not $item.ToolsRunning) {
        throw 'VMware Tools is not running and -HardReset was not given. Refusing a hard reset by default.'
    }
    Restart-VMGuest -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null
}

$toolsState = 'not waited for'
if ($WaitForToolsSeconds -gt 0) {
    Start-Sleep -Seconds 10
    $deadline = (Get-Date).AddSeconds($WaitForToolsSeconds)
    do {
        Start-Sleep -Seconds 5
        $toolsState = (Get-VM -Name $item.VMName).ExtensionData.Guest.ToolsRunningStatus
    } while ($toolsState -ne 'guestToolsRunning' -and (Get-Date) -lt $deadline)
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Restart via {0} complete. Tools state: {1}' -f $item.Method, $toolsState)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Restarted'; Detail = ('{0}; tools {1}' -f $item.Method, $toolsState)
    Succeeded = $true })
"""),

10: dict(
    file='Get-VmwareRdmReport',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Lists raw device mapping (RDM) disks across the vSphere estate.',
    desc='Finds every RDM with its compatibility mode, LUN identifier and owning VM. RDMs are worth '
         'tracking because they block Storage vMotion and snapshot operations in ways that only '
         'surface when someone tries and fails.',
    params=[VC, CRED, VM, CLUSTER],
    perms='vSphere read-only role.',
    examples=[("-VIServer vcenter01 -OutputFormat CSV",
               'Exports every RDM in the estate.'),
              ("-VIServer vcenter01 -ClusterName PROD",
               'Lists RDMs for one cluster.')],
    discover=CONNECT + """
$vms = if ($VMName)          { Get-VM -Name $VMName -ErrorAction Stop }
       elseif ($ClusterName) { Get-Cluster -Name $ClusterName | Get-VM }
       else                  { Get-VM }

$found = 0
foreach ($vm in $vms) {
    # RawPhysical and RawVirtual are the two RDM compatibility modes; flat is a
    # normal VMDK and is not an RDM.
    foreach ($hd in (Get-HardDisk -VM $vm | Where-Object { $_.DiskType -match 'Raw' })) {
        $found++
        $results.Add([PSCustomObject]@{
            Name             = ('{0} / {1}' -f $vm.Name, $hd.Name)
            Id               = $hd.Id
            VMName           = $vm.Name
            PowerState       = "$($vm.PowerState)"
            DiskName         = $hd.Name
            CapacityGB       = [math]::Round($hd.CapacityGB, 2)
            CompatibilityMode= "$($hd.DiskType)"
            ScsiCanonicalName= $hd.ScsiCanonicalName
            DeviceName       = $hd.DeviceName
            Filename         = $hd.Filename
            VMHost           = $vm.VMHost.Name
            Constraint       = 'RDM - blocks Storage vMotion and some snapshot operations'
        })
    }
}

if ($found -eq 0) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'No RDM disks found in scope.'
}
"""),

11: dict(
    file='Set-VmwareVmCompute',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Resizes vSphere virtual machine CPU and memory.',
    desc='Changes vCPU count and memory on a VM. Whether this needs downtime depends on hot-add: '
         'the script reads the hot-add settings and reports up front whether the change can be '
         'applied live or requires the VM to be powered off, rather than failing partway.',
    params=[VC, CRED,
            dict(name='TargetVMName', help='Virtual machine to resize.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$TargetVMName"),
            dict(name='NewNumCpu', help='New vCPU count. Omit to leave unchanged.',
                 decl="[ValidateRange(1,128)]\n    [int]$NewNumCpu = 0"),
            dict(name='NewMemoryGB', help='New memory in GB. Omit to leave unchanged.',
                 decl="[ValidateRange(1,6144)]\n    [int]$NewMemoryGB = 0"),
            dict(name='AllowPowerOff', help='Permit the script to power the VM off when hot-add is unavailable. Off by default.',
                 decl="[switch]$AllowPowerOff")],
    perms='vSphere role with Virtual machine > Configuration > Change CPU count and Change memory.',
    actionVerb='Resize VM compute',
    reason='VM compute resize',
    rollback='Re-run with the previous values, which are recorded in the approval artifact and the '
             'audit log before the change is applied.',
    notes='Reducing vCPU or memory ALWAYS requires a power-off; only increases can be hot-added, '
          'and only when hot-add is enabled on the VM. The script reports which case applies before '
          'asking for approval.',
    examples=[("-VIServer vcenter01 -TargetVMName APP01 -NewNumCpu 8 -NewMemoryGB 32",
               'REQUEST mode - reports whether hot-add covers the change and raises an approval.'),
              ("-VIServer vcenter01 -TargetVMName APP01 -NewMemoryGB 32 -ApprovalReference APR-... -AllowPowerOff",
               'Applies the approved change, powering the VM off if required.')],
    discover=CONNECT + """
if ($NewNumCpu -eq 0 -and $NewMemoryGB -eq 0) {
    throw 'Specify -NewNumCpu, -NewMemoryGB or both. Nothing to change.'
}

foreach ($vm in (Get-VM -Name $TargetVMName -ErrorAction Stop)) {
    $cpuHotAdd = $vm.ExtensionData.Config.CpuHotAddEnabled
    $memHotAdd = $vm.ExtensionData.Config.MemoryHotAddEnabled

    $cpuChange = ($NewNumCpu   -gt 0 -and $NewNumCpu   -ne $vm.NumCpu)
    $memChange = ($NewMemoryGB -gt 0 -and $NewMemoryGB -ne $vm.MemoryGB)
    if (-not $cpuChange -and -not $memChange) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $vm.Name `
            -Message 'Skipped - already at the requested size (idempotent)'
        continue
    }

    # A decrease can never be hot-applied, whatever the hot-add settings say.
    $cpuDecrease = ($NewNumCpu   -gt 0 -and $NewNumCpu   -lt $vm.NumCpu)
    $memDecrease = ($NewMemoryGB -gt 0 -and $NewMemoryGB -lt $vm.MemoryGB)

    $needsPowerOff = $false
    $reasons = @()
    if ($vm.PowerState -eq 'PoweredOn') {
        if ($cpuDecrease) { $needsPowerOff = $true; $reasons += 'vCPU decrease' }
        if ($memDecrease) { $needsPowerOff = $true; $reasons += 'memory decrease' }
        if ($cpuChange -and -not $cpuDecrease -and -not $cpuHotAdd) { $needsPowerOff = $true; $reasons += 'CPU hot-add disabled' }
        if ($memChange -and -not $memDecrease -and -not $memHotAdd) { $needsPowerOff = $true; $reasons += 'memory hot-add disabled' }
    }

    $results.Add([PSCustomObject]@{
        Name           = $vm.Name
        Id             = $vm.Id
        VMName         = $vm.Name
        PowerState     = "$($vm.PowerState)"
        CurrentNumCpu  = $vm.NumCpu
        CurrentMemoryGB= $vm.MemoryGB
        NewNumCpu      = if ($NewNumCpu -gt 0) { $NewNumCpu } else { $vm.NumCpu }
        NewMemoryGB    = if ($NewMemoryGB -gt 0) { $NewMemoryGB } else { $vm.MemoryGB }
        CpuHotAdd      = $cpuHotAdd
        MemoryHotAdd   = $memHotAdd
        RequiresPowerOff = $needsPowerOff
        PowerOffReason = ($reasons -join '; ')
    })
}
""",
    act="""
$vmObj = Get-VM -Name $item.VMName -ErrorAction Stop

if ($item.RequiresPowerOff -and -not $AllowPowerOff) {
    throw ('{0} requires a power-off ({1}) and -AllowPowerOff was not given. VM left untouched.' -f
           $item.VMName, $item.PowerOffReason)
}

$poweredOffByUs = $false
if ($item.RequiresPowerOff -and $vmObj.PowerState -eq 'PoweredOn') {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
        'Powering off for the resize: {0}' -f $item.PowerOffReason)
    if ($vmObj.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning') {
        Stop-VMGuest -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null
        $deadline = (Get-Date).AddSeconds(300)
        do { Start-Sleep -Seconds 5; $st = (Get-VM -Name $item.VMName).PowerState }
        while ("$st" -ne 'PoweredOff' -and (Get-Date) -lt $deadline)
    }
    if ((Get-VM -Name $item.VMName).PowerState -ne 'PoweredOff') {
        Stop-VM -VM $vmObj -Confirm:$false -ErrorAction Stop | Out-Null
    }
    $poweredOffByUs = $true
}

$setParams = @{ VM = (Get-VM -Name $item.VMName); Confirm = $false; ErrorAction = 'Stop' }
if ($item.NewNumCpu   -ne $item.CurrentNumCpu)   { $setParams.NumCpu   = $item.NewNumCpu }
if ($item.NewMemoryGB -ne $item.CurrentMemoryGB) { $setParams.MemoryGB = $item.NewMemoryGB }
Set-VM @setParams | Out-Null

if ($poweredOffByUs) {
    Start-VM -VM (Get-VM -Name $item.VMName) -Confirm:$false -ErrorAction Stop | Out-Null
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message 'Powered back on after the resize'
}

$after = Get-VM -Name $item.VMName
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Resized: {0}vCPU/{1}GB -> {2}vCPU/{3}GB' -f
    $item.CurrentNumCpu, $item.CurrentMemoryGB, $after.NumCpu, $after.MemoryGB)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Resized'
    Detail = ('{0}vCPU/{1}GB -> {2}vCPU/{3}GB' -f $item.CurrentNumCpu, $item.CurrentMemoryGB, $after.NumCpu, $after.MemoryGB)
    Succeeded = $true })
"""),

12: dict(
    file='Get-VmwareHostAdapterReport',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Reports ESXi host vNIC and HBA adapter and driver detail.',
    desc='Collects physical NIC and storage HBA inventory per host with driver and firmware detail '
         'where the host exposes it. Driver version drift across hosts in the same cluster is the '
         'condition this surfaces - it causes failures that look random until you compare hosts.',
    params=[VC, CRED, CLUSTER,
            dict(name='VMHostName', help='Limit to specific ESXi hosts.',
                 decl="[string[]]$VMHostName")],
    perms='vSphere read-only role. Driver detail additionally needs host CLI access through the API.',
    notes='Driver and firmware detail comes from esxcli through the vSphere API. Where a host does '
          'not expose it, the adapter is still reported with the driver fields null rather than '
          'omitted, so the gap is visible.',
    examples=[("-VIServer vcenter01 -ClusterName PROD -OutputFormat CSV",
               'Exports adapter inventory for a cluster.'),
              ("-VIServer vcenter01 -VMHostName esx01.contoso.com",
               'Reports one host.')],
    discover=CONNECT + """
$vmHosts = if ($VMHostName)  { Get-VMHost -Name $VMHostName -ErrorAction Stop }
           elseif ($ClusterName) { Get-Cluster -Name $ClusterName | Get-VMHost }
           else                  { Get-VMHost }

foreach ($h in $vmHosts) {
    if ($h.ConnectionState -ne 'Connected') {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $h.Name `
            -Message ('Skipped - host is {0}' -f $h.ConnectionState)
        continue
    }

    $esxcli = $null
    try { $esxcli = Get-EsxCli -VMHost $h -V2 -ErrorAction Stop }
    catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $h.Name `
            -Message ('esxcli unavailable; driver detail will be null: {0}' -f $_.Exception.Message)
    }

    foreach ($nic in (Get-VMHostNetworkAdapter -VMHost $h -Physical -ErrorAction SilentlyContinue)) {
        $driver = $null; $driverVer = $null; $fw = $null
        if ($esxcli) {
            try {
                $info = $esxcli.network.nic.get.Invoke(@{ nicname = $nic.Name })
                $driver    = $info.DriverInfo.Driver
                $driverVer = $info.DriverInfo.Version
                $fw        = $info.DriverInfo.FirmwareVersion
            } catch {
                Write-Verbose ('No esxcli detail for {0}/{1}' -f $h.Name, $nic.Name)
            }
        }
        $results.Add([PSCustomObject]@{
            Name          = ('{0} / {1}' -f $h.Name, $nic.Name)
            Id            = $nic.Name
            VMHost        = $h.Name
            Cluster       = $h.Parent.Name
            AdapterType   = 'vmnic'
            AdapterName   = $nic.Name
            MacAddress    = $nic.Mac
            LinkSpeedMb   = $nic.BitRatePerSec
            Driver        = $driver
            DriverVersion = $driverVer
            Firmware      = $fw
            EsxiVersion   = $h.Version
            EsxiBuild     = $h.Build
        })
    }

    foreach ($hba in (Get-VMHostHba -VMHost $h -ErrorAction SilentlyContinue)) {
        $results.Add([PSCustomObject]@{
            Name          = ('{0} / {1}' -f $h.Name, $hba.Device)
            Id            = $hba.Device
            VMHost        = $h.Name
            Cluster       = $h.Parent.Name
            AdapterType   = "HBA-$($hba.Type)"
            AdapterName   = $hba.Device
            MacAddress    = $null
            LinkSpeedMb   = $null
            Driver        = $hba.Driver
            DriverVersion = $null
            Firmware      = $hba.Model
            EsxiVersion   = $h.Version
            EsxiBuild     = $h.Build
            HbaStatus     = "$($hba.Status)"
        })
    }
}
"""),

13: dict(
    file='Get-VmwareVsanHealth',
    modules=['VMware.VimAutomation.Core'],
    synopsis='Reports vSAN cluster health, capacity and resync status.',
    desc='For each vSAN-enabled cluster, reports capacity and free space, disk group health, object '
         'compliance and any active resynchronisation. Resync activity matters because a cluster '
         'that is rebuilding is temporarily less able to survive another failure.',
    params=[VC, CRED, CLUSTER,
            dict(name='MinimumFreePercent', help='Flag a vSAN datastore below this free percentage.',
                 decl="[ValidateRange(1,99)]\n    [int]$MinimumFreePercent = 25")],
    perms='vSphere read-only role with vSAN view privileges.',
    notes='vSAN best practice keeps 25-30% slack space for rebuilds and maintenance, which is why '
          'the default free-space floor here is higher than for a normal datastore.',
    examples=[("-VIServer vcenter01 -OutputFormat HTML",
               'vSAN health report for every vSAN cluster.'),
              ("-VIServer vcenter01 -ClusterName VSAN-PROD -MinimumFreePercent 30",
               'Checks one cluster against a 30% slack requirement.')],
    discover=CONNECT + """
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
"""),
}
