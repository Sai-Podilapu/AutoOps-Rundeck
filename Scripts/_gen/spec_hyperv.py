# -*- coding: utf-8 -*-
"""Hyper-V - 12 use cases. Real Hyper-V / FailoverClusters cmdlets."""

HOST = dict(name='ComputerName', help='Hyper-V host(s) to act against. Defaults to the local host.',
            decl="[string[]]$ComputerName = $env:COMPUTERNAME")
VMNAME = dict(name='VMName', help='Limit to specific virtual machines. Wildcards are accepted for reporting scripts only.',
              decl="[string[]]$VMName")
CRED = dict(name='Credential', help='Credential for the remote Hyper-V host.',
            decl="[System.Management.Automation.PSCredential]\n    [System.Management.Automation.Credential()]\n    $Credential = [System.Management.Automation.PSCredential]::Empty")

SPECS = {

1: dict(
    file='New-HvVmCheckpoint',
    modules=['Hyper-V'],
    synopsis='Creates a production checkpoint for virtual machines before a change.',
    desc='Takes a checkpoint of each selected VM, named with the reason and a timestamp so the '
         'purpose is readable months later. Production checkpoints are used where the guest '
         'supports them, because they use VSS and leave an application-consistent image rather '
         'than a saved-state one.',
    params=[HOST, VMNAME, CRED,
            dict(name='CheckpointReason', help='Short reason recorded in the checkpoint name.',
                 decl="[ValidateNotNullOrEmpty()]\n    [string]$CheckpointReason = 'pre-change'"),
            dict(name='SkipIfRecentHours', help='Skip a VM that already has a checkpoint newer than this. Makes a re-run idempotent instead of stacking checkpoints.',
                 decl="[ValidateRange(0,720)]\n    [int]$SkipIfRecentHours = 4")],
    perms='Hyper-V Administrators on the host.',
    actionVerb='Create VM checkpoint',
    rollback='A checkpoint is additive and can be removed with Remove-HvVmCheckpoint. It changes '
             'nothing about the running VM.',
    examples=[("-ComputerName HV01 -VMName APP01,APP02 -CheckpointReason 'pre-patch'",
               'Checkpoints two VMs before patching.'),
              ("-ComputerName HV01 -WhatIf",
               'Shows which VMs would be checkpointed.')],
    discover="""
foreach ($hv in $ComputerName) {
    $hvArgs = @{ ComputerName = $hv; ErrorAction = 'Stop' }
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

    $vms = if ($VMName) { Get-VM -Name $VMName @hvArgs } else { Get-VM @hvArgs }
    foreach ($vm in $vms) {
        if ($SkipIfRecentHours -gt 0) {
            $recent = Get-VMSnapshot -VMName $vm.Name @hvArgs -ErrorAction SilentlyContinue |
                Where-Object { $_.CreationTime -gt (Get-Date).AddHours(-$SkipIfRecentHours) }
            if ($recent) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}\\{1}' -f $hv, $vm.Name) `
                    -Message ('Skipped - checkpoint taken within the last {0}h' -f $SkipIfRecentHours)
                continue
            }
        }
        $results.Add([PSCustomObject]@{
            Name           = ('{0}\\{1}' -f $hv, $vm.Name)
            Id             = $vm.Id
            VMName         = $vm.Name
            HyperVHost     = $hv
            State          = $vm.State
            CheckpointType = $vm.CheckpointType
            SnapshotName   = ('{0}-{1}-{2}' -f $vm.Name, $CheckpointReason, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        })
    }
}
""",
    act="""
$hvArgs = @{ ComputerName = $item.HyperVHost; ErrorAction = 'Stop' }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

Checkpoint-VM -Name $item.VMName -SnapshotName $item.SnapshotName @hvArgs
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Checkpoint created: {0}' -f $item.SnapshotName)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'CheckpointCreated'; Detail = $item.SnapshotName; Succeeded = $true })
"""),

2: dict(
    file='Remove-HvVmCheckpoint',
    modules=['Hyper-V'],
    synopsis='Removes Hyper-V checkpoints older than a minimum age.',
    desc='Deletes checkpoints beyond the retention age. The age rule is the safety control the '
         'workbook specifies: a checkpoint taken minutes ago is almost certainly load-bearing for '
         'a change in flight, while one older than a week is usually forgotten and is quietly '
         'costing disk and IO.',
    params=[HOST, VMNAME, CRED,
            dict(name='MinimumAgeDays', help='Only remove checkpoints older than this. The workbook guardrail specifies a >7 day rule, which is the default.',
                 decl="[ValidateRange(1,3650)]\n    [int]$MinimumAgeDays = 7"),
            dict(name='KeepLatest', help='Always keep this many of the newest checkpoints per VM regardless of age.',
                 decl="[ValidateRange(0,50)]\n    [int]$KeepLatest = 1")],
    perms='Hyper-V Administrators on the host.',
    actionVerb='Remove VM checkpoint',
    rollback='NONE. Removing a checkpoint merges its differencing disk into the parent and cannot '
             'be undone. The age rule and -KeepLatest exist because there is no recovery.',
    notes='Removing a checkpoint triggers a disk merge, which generates significant storage IO on '
          'the host. Schedule outside peak hours - the merge impact is the reason this is Medium '
          'risk rather than Low.',
    examples=[("-ComputerName HV01 -MinimumAgeDays 7",
               'Removes checkpoints older than a week, keeping the newest one per VM.'),
              ("-ComputerName HV01 -MinimumAgeDays 30 -KeepLatest 0 -WhatIf",
               'Shows what a 30-day purge would remove.')],
    discover="""
foreach ($hv in $ComputerName) {
    $hvArgs = @{ ComputerName = $hv; ErrorAction = 'Stop' }
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

    $vms = if ($VMName) { Get-VM -Name $VMName @hvArgs } else { Get-VM @hvArgs }
    foreach ($vm in $vms) {
        $snaps = @(Get-VMSnapshot -VMName $vm.Name @hvArgs -ErrorAction SilentlyContinue |
                   Sort-Object CreationTime -Descending)
        if ($snaps.Count -eq 0) { continue }

        # Keep the newest N regardless of age, then apply the age rule to the rest.
        $eligible = if ($KeepLatest -gt 0) { $snaps | Select-Object -Skip $KeepLatest } else { $snaps }
        $cutoff = (Get-Date).AddDays(-$MinimumAgeDays)

        foreach ($s in $eligible) {
            if ($s.CreationTime -ge $cutoff) { continue }
            $results.Add([PSCustomObject]@{
                Name         = ('{0}\\{1}\\{2}' -f $hv, $vm.Name, $s.Name)
                Id           = $s.Id
                VMName       = $vm.Name
                HyperVHost   = $hv
                SnapshotName = $s.Name
                CreatedAt    = $s.CreationTime
                AgeDays      = [math]::Round(((Get-Date) - $s.CreationTime).TotalDays, 1)
                SizeNote     = 'merge IO on removal'
            })
        }
    }
}
""",
    act="""
$hvArgs = @{ ComputerName = $item.HyperVHost; ErrorAction = 'Stop' }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

Remove-VMSnapshot -VMName $item.VMName -Name $item.SnapshotName @hvArgs -Confirm:$false
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Checkpoint removed (age {0}d). Disk merge now in progress on the host.' -f $item.AgeDays)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'CheckpointRemoved'; Detail = ('age {0}d' -f $item.AgeDays); Succeeded = $true })
"""),

3: dict(
    file='Set-HvVmPowerState',
    modules=['Hyper-V'],
    synopsis='Starts, stops or restarts Hyper-V virtual machines with logging.',
    desc='Performs a controlled power operation on selected VMs. Shutdown and restart request a '
         'graceful guest shutdown through integration services and only fall back to a hard turn-off '
         'when -Force is given, because pulling power on a running guest risks filesystem damage.',
    params=[HOST, VMNAME, CRED,
            dict(name='Operation', help='Start, Shutdown, Restart or TurnOff. TurnOff is the hard power cut and is never the default.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Start','Shutdown','Restart','TurnOff')]\n    [string]$Operation"),
            dict(name='Force', help='Allow a hard turn-off when a graceful shutdown does not complete in time.',
                 decl="[switch]$Force"),
            dict(name='TimeoutSeconds', help='How long to wait for a graceful shutdown before reporting failure.',
                 decl="[ValidateRange(10,3600)]\n    [int]$TimeoutSeconds = 300")],
    perms='Hyper-V Administrators on the host.',
    actionVerb='Change VM power state',
    rollback='Reverse the operation. A hard TurnOff may leave the guest filesystem dirty - that is '
             'why it requires an explicit choice rather than being a fallback.',
    examples=[("-ComputerName HV01 -VMName APP01 -Operation Shutdown",
               'Requests a graceful guest shutdown of APP01.'),
              ("-ComputerName HV01 -VMName APP01 -Operation Restart -WhatIf",
               'Shows the restart without performing it.')],
    discover="""
foreach ($hv in $ComputerName) {
    $hvArgs = @{ ComputerName = $hv; ErrorAction = 'Stop' }
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

    $vms = if ($VMName) { Get-VM -Name $VMName @hvArgs } else { Get-VM @hvArgs }
    foreach ($vm in $vms) {
        # Idempotency: skip a VM already in the requested end state.
        $alreadyThere = switch ($Operation) {
            'Start'    { $vm.State -eq 'Running' }
            'Shutdown' { $vm.State -eq 'Off' }
            'TurnOff'  { $vm.State -eq 'Off' }
            default    { $false }
        }
        if ($alreadyThere) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}\\{1}' -f $hv, $vm.Name) `
                -Message ('Skipped - already {0}' -f $vm.State)
            continue
        }
        $results.Add([PSCustomObject]@{
            Name         = ('{0}\\{1}' -f $hv, $vm.Name)
            Id           = $vm.Id
            VMName       = $vm.Name
            HyperVHost   = $hv
            CurrentState = "$($vm.State)"
            Operation    = $Operation
            IntegrationServices = $vm.IntegrationServicesState
            Uptime       = $vm.Uptime
        })
    }
}
""",
    act="""
$hvArgs = @{ ComputerName = $item.HyperVHost; ErrorAction = 'Stop' }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

$wantedState = switch ($Operation) {
    'Start'    { 'Running' }
    'Shutdown' { 'Off' }
    'TurnOff'  { 'Off' }
    'Restart'  { 'Running' }
}

switch ($Operation) {
    'Start' {
        Start-VM -Name $item.VMName @hvArgs
    }
    'Shutdown' {
        # Graceful first. -Force here only suppresses the confirmation prompt;
        # it does not turn the guest off abruptly.
        Stop-VM -Name $item.VMName -Force:$Force @hvArgs
    }
    'Restart' {
        Restart-VM -Name $item.VMName -Force:$Force @hvArgs
    }
    'TurnOff' {
        # The hard power cut. Explicitly chosen by the operator, never a fallback.
        Stop-VM -Name $item.VMName -TurnOff -Force @hvArgs
    }
}

# Wait for the requested end state rather than assuming the cmdlet returning
# means the guest got there. A guest that ignores the shutdown request is the
# common case this catches.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Seconds 3
    $after = (Get-VM -Name $item.VMName @hvArgs).State
} while ("$after" -ne $wantedState -and (Get-Date) -lt $deadline)

if ("$after" -ne $wantedState) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
        'Still {0} after {1}s (wanted {2}). The guest may be ignoring the request.' -f
        $after, $TimeoutSeconds, $wantedState)
}
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} completed: {1} -> {2}' -f $Operation, $item.CurrentState, $after)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $Operation
    Detail = ('{0} -> {1}' -f $item.CurrentState, $after)
    Succeeded = ("$after" -eq $wantedState) })
"""),

4: dict(
    file='New-HvVirtualMachine',
    modules=['Hyper-V'],
    synopsis='Provisions a new Hyper-V virtual machine from an approved specification.',
    desc='Creates a Generation 2 VM with the requested CPU, memory, disk and network, then leaves '
         'it powered off for the build process to take over. Host capacity is checked before the '
         'VM is created, because the workbook guardrail for this row is capacity impact.',
    params=[HOST, CRED,
            dict(name='NewVMName', help='Name of the VM to create.',
                 decl="[Parameter(Mandatory)]\n    [ValidateNotNullOrEmpty()]\n    [string]$NewVMName"),
            dict(name='MemoryStartupGB', help='Startup memory in GB.',
                 decl="[ValidateRange(1,1024)]\n    [int]$MemoryStartupGB = 4"),
            dict(name='ProcessorCount', help='Virtual processor count.',
                 decl="[ValidateRange(1,240)]\n    [int]$ProcessorCount = 2"),
            dict(name='DiskSizeGB', help='Size of the new system VHDX in GB.',
                 decl="[ValidateRange(10,65536)]\n    [int]$DiskSizeGB = 100"),
            dict(name='SwitchName', help='Virtual switch to connect the VM to.',
                 decl="[Parameter(Mandatory)]\n    [string]$SwitchName"),
            dict(name='VhdPath', help='Directory for the new VHDX. Defaults to the host default virtual hard disk path.',
                 decl="[string]$VhdPath"),
            dict(name='MinimumHostFreeGB', help='Refuse to provision if the host storage would drop below this.',
                 decl="[ValidateRange(0,100000)]\n    [int]$MinimumHostFreeGB = 100")],
    perms='Hyper-V Administrators on the host, plus write access to the VHD path.',
    actionVerb='Provision new VM',
    reason='New VM provisioning',
    rollback='Remove-VM plus deletion of the VHDX. The VM is created powered off, so a mistaken '
             'provision consumes storage but affects no running workload.',
    examples=[("-ComputerName HV01 -NewVMName APP03 -SwitchName 'Prod-vSwitch' -MemoryStartupGB 8 -ProcessorCount 4",
               'REQUEST mode - produces the spec and raises an approval, creating nothing.'),
              ("-ComputerName HV01 -NewVMName APP03 -SwitchName 'Prod-vSwitch' -ApprovalReference APR-...",
               'Creates the VM after the specification has been approved.')],
    discover="""
foreach ($hv in $ComputerName) {
    $hvArgs = @{ ComputerName = $hv; ErrorAction = 'Stop' }
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

    # Refuse a duplicate name before anything else - this is not idempotent by
    # nature and a second VM with the same name is a real incident.
    $existing = Get-VM -Name $NewVMName @hvArgs -ErrorAction SilentlyContinue
    if ($existing) {
        throw ('A VM named {0} already exists on {1}. Refusing to provision a duplicate.' -f $NewVMName, $hv)
    }

    $hostInfo = Get-VMHost @hvArgs
    $targetPath = if ($VhdPath) { $VhdPath } else { $hostInfo.VirtualHardDiskPath }

    # Capacity check - the workbook guardrail for this row.
    $drive = Split-Path -Qualifier $targetPath
    $freeGB = $null
    try {
        $cim = @{ ClassName = 'Win32_LogicalDisk'; Filter = "DeviceID='$drive'"; ErrorAction = 'Stop' }
        if ($hv -ne $env:COMPUTERNAME) { $cim.ComputerName = $hv }
        $freeGB = [math]::Round((Get-CimInstance @cim).FreeSpace / 1GB, 1)
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $hv `
            -Message ('Could not read free space on {0}: {1}' -f $drive, $_.Exception.Message)
    }
    if ($null -ne $freeGB -and ($freeGB - $DiskSizeGB) -lt $MinimumHostFreeGB) {
        throw ('Refusing to provision: {0} would leave {1}GB free on {2}, below the {3}GB floor.' -f
               $hv, [math]::Round($freeGB - $DiskSizeGB, 1), $drive, $MinimumHostFreeGB)
    }

    $results.Add([PSCustomObject]@{
        Name            = ('{0}\\{1}' -f $hv, $NewVMName)
        Id              = $NewVMName
        VMName          = $NewVMName
        HyperVHost      = $hv
        MemoryStartupGB = $MemoryStartupGB
        ProcessorCount  = $ProcessorCount
        DiskSizeGB      = $DiskSizeGB
        SwitchName      = $SwitchName
        VhdFullPath     = (Join-Path $targetPath ('{0}.vhdx' -f $NewVMName))
        HostFreeGB      = $freeGB
        HostFreeAfterGB = if ($null -ne $freeGB) { [math]::Round($freeGB - $DiskSizeGB, 1) } else { $null }
    })
}
""",
    act="""
$hvArgs = @{ ComputerName = $item.HyperVHost; ErrorAction = 'Stop' }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

New-VM -Name $item.VMName -MemoryStartupBytes ($item.MemoryStartupGB * 1GB) `
       -NewVHDPath $item.VhdFullPath -NewVHDSizeBytes ($item.DiskSizeGB * 1GB) `
       -SwitchName $item.SwitchName -Generation 2 @hvArgs | Out-Null

Set-VMProcessor -VMName $item.VMName -Count $item.ProcessorCount @hvArgs

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'VM provisioned: {0} vCPU, {1}GB RAM, {2}GB disk on {3}. Left powered OFF for build.' -f
    $item.ProcessorCount, $item.MemoryStartupGB, $item.DiskSizeGB, $item.SwitchName)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Provisioned'; Detail = $item.VhdFullPath; Succeeded = $true })
"""),

5: dict(
    file='Get-HvHostHealthReport',
    modules=['Hyper-V'],
    synopsis='Reports Hyper-V host CPU, memory, storage and network health.',
    desc='Collects host-level capacity and headroom: logical processors against assigned virtual '
         'processors, physical memory against assigned VM memory, virtual hard disk path free '
         'space, and virtual switch state. Reports the overcommit ratio, which is the number that '
         'actually predicts trouble on a Hyper-V host.',
    params=[HOST, CRED,
            dict(name='MinimumFreeDiskPercent', help='Flag a host whose VHD storage drops below this.',
                 decl="[ValidateRange(1,100)]\n    [int]$MinimumFreeDiskPercent = 15"),
            dict(name='MaxCpuOvercommitRatio', help='Flag a host whose virtual-to-logical processor ratio exceeds this.',
                 decl="[ValidateRange(1,64)]\n    [double]$MaxCpuOvercommitRatio = 4")],
    perms='Read access to Hyper-V WMI on the host.',
    examples=[("-ComputerName HV01,HV02 -OutputFormat HTML",
               'Health report for two hosts as HTML.'),
              ("-ComputerName HV01 -MaxCpuOvercommitRatio 2",
               'Applies a tighter overcommit threshold.')],
    discover="""
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
"""),

6: dict(
    file='Move-HvVirtualMachine',
    modules=['Hyper-V'],
    synopsis='Live migrates a virtual machine to another Hyper-V host.',
    desc='Performs a live migration of a running VM to a destination host. Live migration is '
         'zero-downtime in theory, but a failure mid-migration affects a production workload, so '
         'this script validates the destination has capacity and that live migration is enabled on '
         'both ends before it starts, and verifies the VM is running on the destination afterwards.',
    params=[CRED,
            dict(name='SourceHost', help='Current Hyper-V host.',
                 decl="[Parameter(Mandatory)]\n    [string]$SourceHost"),
            dict(name='DestinationHost', help='Target Hyper-V host.',
                 decl="[Parameter(Mandatory)]\n    [string]$DestinationHost"),
            dict(name='MigrateVMName', help='Virtual machine to migrate.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$MigrateVMName"),
            dict(name='IncludeStorage', help='Perform a shared-nothing migration that moves the VM storage as well.',
                 decl="[switch]$IncludeStorage"),
            dict(name='DestinationStoragePath', help='Storage path on the destination when -IncludeStorage is used.',
                 decl="[string]$DestinationStoragePath")],
    perms='Hyper-V Administrators on BOTH hosts, with constrained delegation or CredSSP configured for live migration.',
    actionVerb='Live migrate VM',
    reason='Planned live migration',
    rollback='Migrate back to the source host. A failed live migration normally leaves the VM '
             'running on the source, which is why the post-migration verification below reports '
             'where the VM actually ended up rather than assuming success.',
    notes='Live migration requires Kerberos constrained delegation or CredSSP between the hosts. '
          'The workbook marks this High risk and approval-gated, and the SOP requires a maintenance '
          'window even though downtime is expected to be zero.',
    examples=[("-SourceHost HV01 -DestinationHost HV02 -MigrateVMName APP01",
               'REQUEST mode - validates and raises an approval, migrating nothing.'),
              ("-SourceHost HV01 -DestinationHost HV02 -MigrateVMName APP01 -ApprovalReference APR-...",
               'Performs the approved migration.')],
    discover="""
$srcArgs = @{ ComputerName = $SourceHost; ErrorAction = 'Stop' }
$dstArgs = @{ ComputerName = $DestinationHost; ErrorAction = 'Stop' }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) {
    $srcArgs.Credential = $Credential; $dstArgs.Credential = $Credential
}

# Both ends must have live migration enabled, or the migration fails partway.
$srcHost = Get-VMHost @srcArgs
$dstHost = Get-VMHost @dstArgs
if (-not $srcHost.VirtualMachineMigrationEnabled) {
    throw ('Live migration is not enabled on the source host {0}.' -f $SourceHost)
}
if (-not $dstHost.VirtualMachineMigrationEnabled) {
    throw ('Live migration is not enabled on the destination host {0}.' -f $DestinationHost)
}

foreach ($name in $MigrateVMName) {
    $vm = Get-VM -Name $name @srcArgs
    if ($vm.State -ne 'Running') {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name `
            -Message ('VM is {0}, not Running - a live migration does not apply' -f $vm.State)
        continue
    }
    if (Get-VM -Name $name @dstArgs -ErrorAction SilentlyContinue) {
        throw ('A VM named {0} already exists on the destination {1}.' -f $name, $DestinationHost)
    }

    $needGB = [math]::Round($vm.MemoryAssigned / 1GB, 2)
    $cim = @{ ClassName = 'Win32_OperatingSystem'; ErrorAction = 'Stop'; ComputerName = $DestinationHost }
    $dstFreeGB = [math]::Round((Get-CimInstance @cim).FreePhysicalMemory * 1KB / 1GB, 2)
    if ($dstFreeGB -lt $needGB) {
        throw ('Destination {0} has {1}GB free memory, VM needs {2}GB. Refusing.' -f
               $DestinationHost, $dstFreeGB, $needGB)
    }

    $results.Add([PSCustomObject]@{
        Name            = ('{0} : {1} -> {2}' -f $name, $SourceHost, $DestinationHost)
        Id              = $vm.Id
        VMName          = $name
        SourceHost      = $SourceHost
        DestinationHost = $DestinationHost
        MemoryAssignedGB= $needGB
        DestFreeMemoryGB= $dstFreeGB
        State           = "$($vm.State)"
        IncludeStorage  = [bool]$IncludeStorage
    })
}
""",
    act="""
$srcArgs = @{ ComputerName = $item.SourceHost; ErrorAction = 'Stop' }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $srcArgs.Credential = $Credential }

Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Starting live migration of {0} ({1}GB assigned memory)' -f $item.VMName, $item.MemoryAssignedGB)

if ($IncludeStorage) {
    if (-not $DestinationStoragePath) {
        throw '-IncludeStorage requires -DestinationStoragePath.'
    }
    Move-VM -Name $item.VMName -DestinationHost $item.DestinationHost `
            -IncludeStorage -DestinationStoragePath $DestinationStoragePath @srcArgs
} else {
    Move-VM -Name $item.VMName -DestinationHost $item.DestinationHost @srcArgs
}

# Post-action verification: confirm where the VM actually is, rather than
# assuming the migration landed.
$dstCheck = @{ ComputerName = $item.DestinationHost; ErrorAction = 'Stop' }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $dstCheck.Credential = $Credential }
$moved = Get-VM -Name $item.VMName @dstCheck

if ($moved -and $moved.State -eq 'Running') {
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Migration verified: {0} is Running on {1}' -f $item.VMName, $item.DestinationHost)
    $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Migrated'; Detail = ('Running on {0}' -f $item.DestinationHost); Succeeded = $true })
} else {
    $state = if ($moved) { $moved.State } else { 'not present' }
    Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label -Message (
        'Migration did not verify - VM is {0} on the destination' -f $state)
    $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Failed'; Detail = ('destination state: {0}' -f $state); Succeeded = $false })
}
"""),

7: dict(
    file='Get-HvReplicationHealth',
    modules=['Hyper-V'],
    synopsis='Reports Hyper-V Replica health and replication lag.',
    desc='Checks every replication-enabled VM for its health state, mode and the age of the last '
         'replicated change. Replication that is technically enabled but hours behind is the '
         'failure this catches - it looks healthy in the console until you need it.',
    params=[HOST, CRED,
            dict(name='MaxLagMinutes', help='Flag replication whose last successful replication is older than this.',
                 decl="[ValidateRange(1,10080)]\n    [int]$MaxLagMinutes = 60")],
    perms='Hyper-V Administrators on the host.',
    examples=[("-ComputerName HV01,HV02", 'Reports replication health across two hosts.'),
              ("-MaxLagMinutes 15 -OutputFormat HTML", 'Applies a tight lag threshold and writes HTML.')],
    discover="""
foreach ($hv in $ComputerName) {
    $hvArgs = @{ ComputerName = $hv; ErrorAction = 'Stop' }
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

    $repl = @(Get-VMReplication @hvArgs -ErrorAction SilentlyContinue)
    if ($repl.Count -eq 0) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $hv -Message 'No replication-enabled VMs on this host'
        continue
    }

    foreach ($r in $repl) {
        $lagMin = $null
        if ($r.LastReplicationTime) {
            $lagMin = [math]::Round(((Get-Date) - $r.LastReplicationTime).TotalMinutes, 1)
        }
        $issues = @()
        if ($r.Health -ne 'Normal')                      { $issues += "health is $($r.Health)" }
        if ($r.State -notin @('Replicating','ReadyForInitialReplication')) { $issues += "state is $($r.State)" }
        if ($null -eq $lagMin)                           { $issues += 'never replicated' }
        elseif ($lagMin -gt $MaxLagMinutes)              { $issues += "lag ${lagMin}min" }

        $results.Add([PSCustomObject]@{
            Name                = ('{0}\\{1}' -f $hv, $r.VMName)
            Id                  = $r.VMName
            HyperVHost          = $hv
            ReplicationState    = "$($r.State)"
            ReplicationHealth   = "$($r.Health)"
            ReplicationMode     = "$($r.Mode)"
            PrimaryServer       = $r.PrimaryServerName
            ReplicaServer       = $r.ReplicaServerName
            LastReplication     = $r.LastReplicationTime
            LagMinutes          = $lagMin
            FrequencySeconds    = $r.FrequencySec
            Status              = if ($issues.Count) { 'Unhealthy' } else { 'Healthy' }
            Issues              = ($issues -join '; ')
        })
        if ($issues.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}\\{1}' -f $hv, $r.VMName) `
                -Message ($issues -join '; ')
        }
    }
}
"""),

8: dict(
    file='Resize-HvVirtualDisk',
    modules=['Hyper-V'],
    synopsis='Expands a Hyper-V virtual hard disk.',
    desc='Grows a VHDX to a new size. Expansion only - the script refuses to shrink, because '
         'shrinking a VHDX below the guest partition layout destroys data. Expanding the VHDX does '
         'not extend the guest partition; that remains a deliberate second step inside the guest, '
         'which is why the workbook marks this ticket-driven.',
    params=[HOST, CRED,
            dict(name='TargetVMName', help='Virtual machine whose disk is being expanded.',
                 decl="[Parameter(Mandatory)]\n    [string]$TargetVMName"),
            dict(name='ControllerLocation', help='Disk location on the controller. Use Get-VMHardDiskDrive to identify it.',
                 decl="[ValidateRange(0,63)]\n    [int]$ControllerLocation = 0"),
            dict(name='NewSizeGB', help='New total size in GB. Must be larger than the current size.',
                 decl="[Parameter(Mandatory)]\n    [ValidateRange(1,65536)]\n    [int]$NewSizeGB")],
    perms='Hyper-V Administrators on the host, plus write access to the VHD path.',
    actionVerb='Expand virtual disk',
    reason='Disk capacity expansion',
    rollback='NONE for the VHDX itself - a VHDX cannot be safely shrunk afterwards. Take a '
             'checkpoint with New-HvVmCheckpoint.ps1 first if you need a way back.',
    notes='Expanding the VHDX does NOT extend the partition or filesystem inside the guest. After '
          'this completes, extend the volume in the guest OS. The script reports the new VHDX size, '
          'not new usable space, and says so in its output.',
    examples=[("-ComputerName HV01 -TargetVMName APP01 -NewSizeGB 200",
               'REQUEST mode - validates and raises an approval, changing nothing.'),
              ("-ComputerName HV01 -TargetVMName APP01 -NewSizeGB 200 -ApprovalReference APR-...",
               'Performs the approved expansion.')],
    discover="""
foreach ($hv in $ComputerName) {
    $hvArgs = @{ ComputerName = $hv; ErrorAction = 'Stop' }
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

    $disk = Get-VMHardDiskDrive -VMName $TargetVMName @hvArgs |
            Where-Object { $_.ControllerLocation -eq $ControllerLocation } |
            Select-Object -First 1
    if (-not $disk) {
        throw ('No hard disk at controller location {0} on VM {1}.' -f $ControllerLocation, $TargetVMName)
    }

    $vhd = Get-VHD -Path $disk.Path -ComputerName $hv -ErrorAction Stop
    $currentGB = [math]::Round($vhd.Size / 1GB, 2)

    # Refuse to shrink. Resize-VHD -ToMinimumSize exists but shrinking below the
    # guest partition layout destroys data, so this script only ever grows.
    if ($NewSizeGB -le $currentGB) {
        throw ('Refusing to resize: requested {0}GB is not larger than the current {1}GB. ' +
               'This script expands only.' -f $NewSizeGB, $currentGB)
    }

    $vm = Get-VM -Name $TargetVMName @hvArgs
    $results.Add([PSCustomObject]@{
        Name           = ('{0}\\{1} : {2}' -f $hv, $TargetVMName, (Split-Path -Leaf $disk.Path))
        Id             = $disk.Path
        VMName         = $TargetVMName
        HyperVHost     = $hv
        VhdPath        = $disk.Path
        VhdType        = "$($vhd.VhdType)"
        CurrentSizeGB  = $currentGB
        NewSizeGB      = $NewSizeGB
        IncreaseGB     = [math]::Round($NewSizeGB - $currentGB, 2)
        VMState        = "$($vm.State)"
        GuestActionRequired = 'Extend the partition inside the guest OS after this completes.'
    })
}
""",
    act="""
Resize-VHD -Path $item.VhdPath -SizeBytes ($item.NewSizeGB * 1GB) -ComputerName $item.HyperVHost -ErrorAction Stop

# Verify the new size rather than assuming it took.
$after = Get-VHD -Path $item.VhdPath -ComputerName $item.HyperVHost
$afterGB = [math]::Round($after.Size / 1GB, 2)

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'VHDX expanded {0}GB -> {1}GB. GUEST ACTION STILL REQUIRED: extend the partition inside the VM.' -f
    $item.CurrentSizeGB, $afterGB)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Expanded'
    Detail = ('{0}GB -> {1}GB; guest partition extension still required' -f $item.CurrentSizeGB, $afterGB)
    Succeeded = ($afterGB -ge $item.NewSizeGB) })
"""),

9: dict(
    file='Get-HvVmInventoryReport',
    modules=['Hyper-V'],
    synopsis='Exports a full inventory of Hyper-V virtual machines.',
    desc='Produces a CPU, memory, disk and network inventory for every VM, including generation, '
         'checkpoint count, integration services state and the virtual switches each VM is '
         'attached to. Intended as the export that feeds a CMDB or a capacity review.',
    params=[HOST, VMNAME, CRED],
    perms='Read access to Hyper-V WMI on the host.',
    examples=[("-ComputerName HV01,HV02 -OutputFormat CSV",
               'Exports the estate inventory to CSV.'),
              ("-ComputerName HV01 -VMName APP01 -OutputFormat JSON",
               'Exports one VM with full nested detail as JSON.')],
    discover="""
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
            Name                = ('{0}\\{1}' -f $hv, $vm.Name)
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
"""),

10: dict(
    file='Set-HvVmNetworkAdapter',
    modules=['Hyper-V'],
    synopsis='Adds or removes a network adapter on a Hyper-V virtual machine.',
    desc='Attaches a new virtual NIC to a switch, or detaches an existing one. A network change on '
         'a running production VM can cut it off from the network, so this is approval-gated and '
         'refuses to remove the last remaining adapter.',
    params=[HOST, CRED,
            dict(name='TargetVMName', help='Virtual machine to modify.',
                 decl="[Parameter(Mandatory)]\n    [string]$TargetVMName"),
            dict(name='Operation', help='Add or Remove.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Add','Remove')]\n    [string]$Operation"),
            dict(name='AdapterName', help='Name of the adapter to add or remove.',
                 decl="[Parameter(Mandatory)]\n    [string]$AdapterName"),
            dict(name='SwitchName', help='Virtual switch to connect to. Required for Add.',
                 decl="[string]$SwitchName"),
            dict(name='VlanId', help='Optional VLAN id to set on an added adapter.',
                 decl="[ValidateRange(0,4094)]\n    [int]$VlanId = 0")],
    perms='Hyper-V Administrators on the host.',
    actionVerb='Add/remove VM network adapter',
    reason='Network adapter change',
    rollback='Reverse the operation - re-add the removed adapter, or remove the added one. Note '
             'that a re-added adapter gets a NEW MAC address unless one is set explicitly, which '
             'can break MAC-based licensing or DHCP reservations in the guest.',
    examples=[("-ComputerName HV01 -TargetVMName APP01 -Operation Add -AdapterName 'Backup' -SwitchName 'Backup-vSwitch'",
               'REQUEST mode - raises an approval to add a backup NIC.'),
              ("-ComputerName HV01 -TargetVMName APP01 -Operation Remove -AdapterName 'Backup' -ApprovalReference APR-...",
               'Removes the adapter after approval.')],
    discover="""
foreach ($hv in $ComputerName) {
    $hvArgs = @{ ComputerName = $hv; ErrorAction = 'Stop' }
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

    $vm   = Get-VM -Name $TargetVMName @hvArgs
    $nics = @(Get-VMNetworkAdapter -VMName $TargetVMName @hvArgs)
    $existing = $nics | Where-Object { $_.Name -eq $AdapterName } | Select-Object -First 1

    if ($Operation -eq 'Add') {
        if (-not $SwitchName) { throw '-SwitchName is required when -Operation is Add.' }
        if ($existing) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $TargetVMName `
                -Message ('Skipped - adapter {0} already exists (idempotent)' -f $AdapterName)
            continue
        }
        $switch = Get-VMSwitch -Name $SwitchName @hvArgs -ErrorAction SilentlyContinue
        if (-not $switch) { throw ('Virtual switch {0} does not exist on {1}.' -f $SwitchName, $hv) }
    } else {
        if (-not $existing) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $TargetVMName `
                -Message ('Skipped - adapter {0} does not exist (idempotent)' -f $AdapterName)
            continue
        }
        # Refuse to strip the last NIC from a running VM - that isolates it.
        if ($nics.Count -le 1) {
            throw ('Refusing to remove the only network adapter from {0}. The VM would lose all connectivity.' -f $TargetVMName)
        }
    }

    $results.Add([PSCustomObject]@{
        Name          = ('{0}\\{1} : {2}' -f $hv, $TargetVMName, $AdapterName)
        Id            = $AdapterName
        VMName        = $TargetVMName
        HyperVHost    = $hv
        Operation     = $Operation
        AdapterName   = $AdapterName
        SwitchName    = $SwitchName
        VlanId        = $VlanId
        VMState       = "$($vm.State)"
        ExistingNics  = $nics.Count
        CurrentSwitch = if ($existing) { $existing.SwitchName } else { $null }
    })
}
""",
    act="""
$hvArgs = @{ ComputerName = $item.HyperVHost; ErrorAction = 'Stop' }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

if ($item.Operation -eq 'Add') {
    Add-VMNetworkAdapter -VMName $item.VMName -Name $item.AdapterName -SwitchName $item.SwitchName @hvArgs
    if ($item.VlanId -gt 0) {
        Set-VMNetworkAdapterVlan -VMName $item.VMName -VMNetworkAdapterName $item.AdapterName `
            -Access -VlanId $item.VlanId @hvArgs
    }
    $detail = 'attached to {0}' -f $item.SwitchName
} else {
    Remove-VMNetworkAdapter -VMName $item.VMName -Name $item.AdapterName @hvArgs
    $detail = 'detached from {0}' -f $item.CurrentSwitch
}

$after = @(Get-VMNetworkAdapter -VMName $item.VMName @hvArgs).Count
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Adapter {0} {1}. VM now has {2} adapter(s).' -f $item.AdapterName, $item.Operation.ToLower(), $after)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
"""),

11: dict(
    file='Get-HvClusterNodeHealth',
    modules=['FailoverClusters'],
    synopsis='Reports Hyper-V failover cluster node, quorum and resource health.',
    desc='Checks each cluster node state, the quorum configuration and witness, cluster shared '
         'volume health, and any resource not online. A cluster with a node down but quorum intact '
         'is a different situation from one that is one failure away from losing quorum, and this '
         'report distinguishes them.',
    params=[dict(name='Cluster', help='Cluster name(s) to check.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Cluster")],
    perms='Read access to the failover cluster.',
    notes='The FailoverClusters cmdlets do not accept -Credential; they run in the caller\'s '
          'Kerberos context. Run this as an account with cluster read rights rather than passing '
          'a credential, and note that in the scheduled task definition.',
    examples=[("-Cluster HVCLUSTER01", 'Reports node, quorum and CSV health.'),
              ("-Cluster HVCLUSTER01 -OutputFormat HTML", 'Writes the health report as HTML.')],
    discover="""
foreach ($cl in $Cluster) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $cl -Message 'Reading cluster health'

    $nodes = @(Get-ClusterNode -Cluster $cl -ErrorAction Stop)
    $up    = @($nodes | Where-Object { $_.State -eq 'Up' })
    $quorum = Get-ClusterQuorum -Cluster $cl -ErrorAction Stop
    $csvs  = @(Get-ClusterSharedVolume -Cluster $cl -ErrorAction SilentlyContinue)
    $badCsv = @($csvs | Where-Object { $_.State -ne 'Online' })
    $res   = @(Get-ClusterResource -Cluster $cl -ErrorAction SilentlyContinue)
    $badRes = @($res | Where-Object { $_.State -ne 'Online' })

    # Node majority quorum survives (n-1)/2 failures. Reporting the margin is
    # more useful than reporting only that quorum is currently held.
    $margin = [math]::Floor(($nodes.Count - 1) / 2) - ($nodes.Count - $up.Count)

    $issues = @()
    if ($up.Count -ne $nodes.Count) { $issues += ('{0} of {1} node(s) down' -f ($nodes.Count - $up.Count), $nodes.Count) }
    if ($badCsv.Count -gt 0)        { $issues += ('{0} CSV(s) not online' -f $badCsv.Count) }
    if ($badRes.Count -gt 0)        { $issues += ('{0} resource(s) not online' -f $badRes.Count) }
    if ($margin -le 0)              { $issues += 'NO REMAINING QUORUM MARGIN - one more failure loses the cluster' }

    $results.Add([PSCustomObject]@{
        Name             = $cl
        Id               = $cl
        NodesTotal       = $nodes.Count
        NodesUp          = $up.Count
        NodesDown        = (($nodes | Where-Object { $_.State -ne 'Up' }).Name -join '; ')
        QuorumType       = "$($quorum.QuorumType)"
        QuorumResource   = $quorum.QuorumResource
        FailureMargin    = $margin
        CsvTotal         = $csvs.Count
        CsvNotOnline     = (($badCsv.Name) -join '; ')
        ResourcesNotOnline = (($badRes.Name) -join '; ')
        Status           = if ($issues.Count) { 'Degraded' } else { 'Healthy' }
        Issues           = ($issues -join '; ')
    })
    if ($issues.Count) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $cl -Message ($issues -join '; ')
    }
}
"""),

12: dict(
    file='Set-HvVmDvdDrive',
    modules=['Hyper-V'],
    synopsis='Mounts or unmounts an ISO on a Hyper-V virtual machine DVD drive.',
    desc='Attaches an ISO image to a VM DVD drive or ejects the current one. Fully reversible and '
         'low risk, which is why it executes directly - but it still logs what was mounted where, '
         'because a forgotten mounted ISO blocks live migration and storage maintenance.',
    params=[HOST, CRED,
            dict(name='TargetVMName', help='Virtual machine to modify.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$TargetVMName"),
            dict(name='Operation', help='Mount or Unmount.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Mount','Unmount')]\n    [string]$Operation"),
            dict(name='IsoPath', help='Path to the ISO, reachable by the Hyper-V host. Required for Mount.',
                 decl="[string]$IsoPath")],
    perms='Hyper-V Administrators on the host, plus host read access to the ISO path.',
    actionVerb='Mount/unmount ISO',
    rollback='Fully reversible - run the opposite operation.',
    examples=[("-ComputerName HV01 -TargetVMName APP01 -Operation Mount -IsoPath '\\\\fs01\\iso\\win2022.iso'",
               'Mounts an ISO on APP01.'),
              ("-ComputerName HV01 -TargetVMName APP01 -Operation Unmount",
               'Ejects whatever is currently mounted.')],
    discover="""
foreach ($hv in $ComputerName) {
    $hvArgs = @{ ComputerName = $hv; ErrorAction = 'Stop' }
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

    if ($Operation -eq 'Mount' -and -not $IsoPath) {
        throw '-IsoPath is required when -Operation is Mount.'
    }

    foreach ($name in $TargetVMName) {
        $vm  = Get-VM -Name $name @hvArgs
        $dvd = Get-VMDvdDrive -VMName $name @hvArgs -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $dvd) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}\\{1}' -f $hv, $name) `
                -Message 'No DVD drive present on this VM'
            continue
        }

        # Idempotency: mounting what is already mounted, or ejecting an empty
        # drive, is a no-op rather than an error.
        if ($Operation -eq 'Mount' -and $dvd.Path -eq $IsoPath) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}\\{1}' -f $hv, $name) `
                -Message 'Skipped - that ISO is already mounted'
            continue
        }
        if ($Operation -eq 'Unmount' -and -not $dvd.Path) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0}\\{1}' -f $hv, $name) `
                -Message 'Skipped - DVD drive is already empty'
            continue
        }

        $results.Add([PSCustomObject]@{
            Name            = ('{0}\\{1}' -f $hv, $name)
            Id              = $name
            VMName          = $name
            HyperVHost      = $hv
            Operation       = $Operation
            CurrentlyMounted= $dvd.Path
            IsoPath         = $IsoPath
            ControllerNumber= $dvd.ControllerNumber
            ControllerLocation = $dvd.ControllerLocation
            VMState         = "$($vm.State)"
        })
    }
}
""",
    act="""
$hvArgs = @{ ComputerName = $item.HyperVHost; ErrorAction = 'Stop' }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $hvArgs.Credential = $Credential }

if ($item.Operation -eq 'Mount') {
    Set-VMDvdDrive -VMName $item.VMName -ControllerNumber $item.ControllerNumber `
        -ControllerLocation $item.ControllerLocation -Path $item.IsoPath @hvArgs
    $detail = 'mounted {0}' -f $item.IsoPath
} else {
    Set-VMDvdDrive -VMName $item.VMName -ControllerNumber $item.ControllerNumber `
        -ControllerLocation $item.ControllerLocation -Path $null @hvArgs
    $detail = 'ejected {0}' -f $item.CurrentlyMounted
}

$after = (Get-VMDvdDrive -VMName $item.VMName @hvArgs | Select-Object -First 1).Path
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} completed. DVD now: {1}' -f $item.Operation, $(if ($after) { $after } else { '<empty>' }))
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
"""),
}
