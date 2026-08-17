# -*- coding: utf-8 -*-
"""Azure - use cases 1-16. Real Az.* module cmdlets."""

SUB = dict(name='SubscriptionId', help='Subscription to operate in. Falls back to azure.defaultSubscriptionId in config.json.',
           decl="[string]$SubscriptionId")
RG = dict(name='ResourceGroupName', help='Limit to specific resource groups.',
          decl="[string[]]$ResourceGroupName")

# Every Azure script selects its subscription explicitly. Relying on whatever
# context happens to be current is how a change lands in the wrong subscription.
SELECT_SUB = """
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
"""

SPECS = {

1: dict(
    file='Set-AzVmPowerState',
    modules=['Az.Accounts', 'Az.Compute'],
    synopsis='Starts, stops (deallocates) or restarts Azure virtual machines.',
    desc='Brings selected VMs to the requested power state. Stop always DEALLOCATES, because a '
         'stopped-but-allocated VM still bills for compute - which defeats the purpose of a power '
         'schedule and is the mistake this script exists to avoid.',
    params=[SUB, RG,
            dict(name='VMName', help='Limit to specific virtual machines.',
                 decl="[string[]]$VMName"),
            dict(name='Operation', help='Start, Stop (deallocate) or Restart.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Start','Stop','Restart')]\n    [string]$Operation"),
            dict(name='TagFilterKey', help='Only act on VMs carrying this tag key.',
                 decl="[string]$TagFilterKey"),
            dict(name='TagFilterValue', help='Tag value to match when -TagFilterKey is given.',
                 decl="[string]$TagFilterValue")],
    perms='Virtual Machine Contributor on the target scope.',
    actionVerb='Change Azure VM power state',
    rollback='Reverse the operation. Deallocation releases the dynamic public IP unless the VM uses '
             'a static one - check before scheduling a stop on anything reached by IP.',
    examples=[("-Operation Stop -TagFilterKey Environment -TagFilterValue dev",
               'Deallocates every dev-tagged VM.'),
              ("-Operation Start -ResourceGroupName rg-prod -WhatIf",
               'Shows which VMs would start.')],
    discover=SELECT_SUB + """
$vms = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ -Status } }
       else                    { Get-AzVM -Status }

if ($VMName) { $vms = $vms | Where-Object { $VMName -contains $_.Name } }

foreach ($vm in $vms) {
    if ($TagFilterKey) {
        $full = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
        $tagVal = $full.Tags[$TagFilterKey]
        if (-not $tagVal) { continue }
        if ($TagFilterValue -and $tagVal -ne $TagFilterValue) { continue }
    }

    $power = ($vm.PowerState -replace '^VM ', '')
    $wanted = switch ($Operation) {
        'Start'   { 'running' }
        'Stop'    { 'deallocated' }
        'Restart' { 'running' }
    }
    # Idempotent: a restart always acts, the other two skip if already there.
    if ($Operation -ne 'Restart' -and $power -eq $wanted) { continue }

    $results.Add([PSCustomObject]@{
        Name          = $vm.Name
        Id            = $vm.Id
        ResourceGroup = $vm.ResourceGroupName
        Location      = $vm.Location
        VmSize        = $vm.HardwareProfile.VmSize
        CurrentState  = $power
        DesiredState  = $wanted
        Operation     = $Operation
    })
}
""",
    act="""
switch ($item.Operation) {
    'Start'   { Start-AzVM   -ResourceGroupName $item.ResourceGroup -Name $item.Name -ErrorAction Stop | Out-Null }
    # -Force suppresses the prompt only; deallocation is what actually stops billing.
    'Stop'    { Stop-AzVM    -ResourceGroupName $item.ResourceGroup -Name $item.Name -Force -ErrorAction Stop | Out-Null }
    'Restart' { Restart-AzVM -ResourceGroupName $item.ResourceGroup -Name $item.Name -ErrorAction Stop | Out-Null }
}

$after = (Get-AzVM -ResourceGroupName $item.ResourceGroup -Name $item.Name -Status).Statuses |
         Where-Object Code -like 'PowerState/*' | Select-Object -First 1 -Expand DisplayStatus
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} complete: {1} -> {2}' -f $item.Operation, $item.CurrentState, $after)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = $item.Operation; Detail = $after; Succeeded = $true })
"""),

2: dict(
    file='Get-AzVmInventory',
    modules=['Az.Accounts', 'Az.Compute', 'Az.Network'],
    synopsis='Exports an inventory of Azure virtual machines.',
    desc='Lists every VM with size, OS, power state, disks, network interfaces, private and public '
         'IP addresses, availability configuration and tags. The export a CMDB or a cost review '
         'actually needs, rather than just names.',
    params=[SUB, RG,
            dict(name='IncludeNetworkDetail', help='Resolve NIC and IP detail. Adds an API call per VM, so it is optional on large estates.',
                 decl="[switch]$IncludeNetworkDetail")],
    perms='Reader on the target scope.',
    examples=[("-OutputFormat CSV", 'Exports the whole subscription to CSV.'),
              ("-ResourceGroupName rg-prod -IncludeNetworkDetail -OutputFormat JSON",
               'Full detail including IPs for one resource group.')],
    discover=SELECT_SUB + """
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
"""),

3: dict(
    file='New-AzDiskSnapshot',
    modules=['Az.Accounts', 'Az.Compute'],
    synopsis='Creates snapshots of Azure managed disks.',
    desc='Snapshots the OS disk, and optionally the data disks, of selected VMs. Additive and safe '
         '- a snapshot is an independent resource and changes nothing about the running VM. Named '
         'with the reason and a timestamp so the purpose stays readable later.',
    params=[SUB, RG,
            dict(name='VMName', help='Virtual machines whose disks to snapshot.',
                 decl="[string[]]$VMName"),
            dict(name='SnapshotReason', help='Short reason recorded in the snapshot name and tags.',
                 decl="[ValidateNotNullOrEmpty()]\n    [string]$SnapshotReason = 'pre-change'"),
            dict(name='IncludeDataDisks', help='Also snapshot data disks, not just the OS disk.',
                 decl="[switch]$IncludeDataDisks"),
            dict(name='SnapshotSku', help='Storage SKU for the snapshot. Standard_LRS is the cheapest and is usually right.',
                 decl="[ValidateSet('Standard_LRS','Standard_ZRS','Premium_LRS')]\n    [string]$SnapshotSku = 'Standard_LRS'")],
    perms='Disk Snapshot Contributor, or Contributor on the resource group.',
    actionVerb='Create disk snapshot',
    rollback='Delete the snapshot with Remove-AzDiskSnapshot.ps1. It is an independent resource and '
             'removing it affects nothing else.',
    notes='Snapshots bill for the storage they occupy for as long as they exist. Pair every '
          'snapshot created here with a retention plan, or Remove-AzDiskSnapshot.ps1 will find them '
          'months later.',
    examples=[("-VMName APP01 -SnapshotReason 'pre-patch'",
               'Snapshots the OS disk of APP01.'),
              ("-ResourceGroupName rg-prod -IncludeDataDisks -WhatIf",
               'Shows every disk that would be snapshotted.')],
    discover=SELECT_SUB + """
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
""",
    act="""
$cfg = New-AzSnapshotConfig -SourceUri $item.Id -Location $item.Location `
    -CreateOption Copy -SkuName $item.SnapshotSku `
    -Tag @{ CreatedBy = $scriptName; Reason = $SnapshotReason; SourceVM = $item.VMName }

New-AzSnapshot -ResourceGroupName $item.ResourceGroup -SnapshotName $item.SnapshotName `
    -Snapshot $cfg -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Snapshot created: {0} ({1})' -f $item.SnapshotName, $item.DiskRole)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'SnapshotCreated'; Detail = $item.SnapshotName; Succeeded = $true })
"""),

4: dict(
    file='Remove-AzDiskSnapshot',
    modules=['Az.Accounts', 'Az.Compute'],
    synopsis='Deletes Azure disk snapshots older than a minimum age.',
    desc='Finds managed disk snapshots beyond the retention age and deletes them. Snapshot deletion '
         'is irreversible, so this is report-only by default and enforces both an age filter and an '
         'optional name pattern before anything is proposed.',
    params=[SUB, RG,
            dict(name='NamePattern', help='Only consider snapshots whose name matches this wildcard pattern.',
                 decl="[string]$NamePattern = '*'"),
            dict(name='ExcludeTagKey', help='Snapshots carrying this tag are never deleted.',
                 decl="[string]$ExcludeTagKey = 'AutoOps:DoNotDelete'")],
    minage=30,
    perms='Contributor on the resource group holding the snapshots.',
    actionVerb='Delete disk snapshot',
    reason='Snapshot retention cleanup',
    rollback='NONE. A deleted snapshot cannot be recovered. The age filter, name pattern and '
             'protected list exist because there is no undo.',
    notes='There is no pre-deletion backup for this row - a snapshot IS the backup. That is exactly '
          'why the age and name filters are enforced rather than advisory.',
    examples=[("-MinimumAgeDays 30",
               'REPORT ONLY. Lists snapshots older than 30 days and raises an approval.'),
              ("-MinimumAgeDays 30 -NamePattern 'pre-patch*' -ApprovalReference APR-... -Execute",
               'Deletes the approved patching snapshots.')],
    discover=SELECT_SUB + """
$snaps = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzSnapshot -ResourceGroupName $_ } }
         else                    { Get-AzSnapshot }

foreach ($s in $snaps) {
    if ($s.Name -notlike $NamePattern) { continue }
    if ($ExcludeTagKey -and $s.Tags -and $s.Tags.ContainsKey($ExcludeTagKey)) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $s.Name `
            -Message ('Excluded - carries the {0} tag' -f $ExcludeTagKey)
        continue
    }

    $results.Add([PSCustomObject]@{
        Name          = $s.Name
        Id            = $s.Id
        ResourceGroup = $s.ResourceGroupName
        Location      = $s.Location
        SizeGB        = $s.DiskSizeGB
        Sku           = $s.Sku.Name
        CreatedAt     = $s.TimeCreated
        AgeDays       = [math]::Round(((Get-Date) - $s.TimeCreated).TotalDays, 1)
        SourceDisk    = if ($s.CreationData.SourceResourceId) { ($s.CreationData.SourceResourceId -split '/')[-1] } else { $null }
        Tags          = if ($s.Tags) { (($s.Tags.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ') } else { '' }
    })
}
""",
    act="""
Remove-AzSnapshot -ResourceGroupName $item.ResourceGroup -SnapshotName $item.Name -Force -ErrorAction Stop | Out-Null
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Snapshot DELETED: {0} ({1}GB, age {2}d). This cannot be undone.' -f $item.Name, $item.SizeGB, $item.AgeDays)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Deleted'
    Detail = ('{0}GB, age {1}d' -f $item.SizeGB, $item.AgeDays); Succeeded = $true })
"""),

5: dict(
    file='New-AzResourceGroupStandard',
    modules=['Az.Accounts', 'Az.Resources'],
    synopsis='Creates resource groups with enforced naming and mandatory tags.',
    desc='Creates a resource group only if its name matches the configured naming convention and '
         'all mandatory tags are supplied. Additive and low risk, but the standards are enforced '
         'here rather than left to the SOP, because a resource group created without an owner tag '
         'is the one nobody can attribute cost to six months later.',
    params=[SUB,
            dict(name='NewResourceGroupName', help='Name of the resource group to create.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$NewResourceGroupName"),
            dict(name='Location', help='Azure region.',
                 decl="[Parameter(Mandatory)]\n    [string]$Location"),
            dict(name='Tag', help='Tags to apply. Must include every key in -MandatoryTagKey.',
                 decl="[hashtable]$Tag = @{}"),
            dict(name='NamingPattern', help='Wildcard pattern the name must match. Set to * to disable the check.',
                 decl="[string]$NamingPattern = 'rg-*'"),
            dict(name='MandatoryTagKey', help='Tag keys that must be present before a group is created.',
                 decl="[string[]]$MandatoryTagKey = @('Owner','Environment','CostCentre')")],
    perms='Contributor at subscription scope.',
    actionVerb='Create resource group',
    rollback='Remove-AzResourceGroup. An empty resource group can be deleted safely; one containing '
             'resources cannot, which is why this script only ever creates empty ones.',
    examples=[("-NewResourceGroupName rg-app-prod -Location uaenorth -Tag @{Owner='ops';Environment='prod';CostCentre='CC100'}",
               'Creates a compliant resource group.'),
              ("-NewResourceGroupName badname -Location uaenorth -WhatIf",
               'Fails the naming check before doing anything.')],
    discover=SELECT_SUB + """
$missingTags = @($MandatoryTagKey | Where-Object { -not $Tag.ContainsKey($_) })
if ($missingTags.Count -gt 0) {
    throw ('Refusing to create: mandatory tag(s) missing - {0}. Supply them via -Tag.' -f ($missingTags -join ', '))
}

foreach ($rgName in $NewResourceGroupName) {
    if ($NamingPattern -ne '*' -and $rgName -notlike $NamingPattern) {
        throw ('Refusing to create "{0}": it does not match the naming pattern "{1}".' -f $rgName, $NamingPattern)
    }

    # Idempotent: an existing group is reported, not recreated.
    $existing = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $rgName `
            -Message ('Skipped - already exists in {0}' -f $existing.Location)
        continue
    }

    $results.Add([PSCustomObject]@{
        Name     = $rgName
        Id       = $rgName
        Location = $Location
        Tags     = (($Tag.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')
        TagCount = $Tag.Count
    })
}
""",
    act="""
New-AzResourceGroup -Name $item.Name -Location $item.Location -Tag $Tag -Force -ErrorAction Stop | Out-Null
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Resource group created in {0} with {1} tag(s)' -f $item.Location, $item.TagCount)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Created'; Detail = $item.Location; Succeeded = $true })
"""),

6: dict(
    file='New-AzVirtualMachine',
    modules=['Az.Accounts', 'Az.Compute', 'Az.Network'],
    synopsis='Provisions an Azure virtual machine from an approved specification.',
    desc='Creates a VM with the requested size, image and network placement. The VM size drives the '
         'monthly bill, so the estimated cost and the size SKU are put in front of the approver '
         'before anything is deployed - which is what the workbook guardrail asks for.',
    params=[SUB,
            dict(name='NewVMName', help='Name of the VM to create.',
                 decl="[Parameter(Mandatory)]\n    [string]$NewVMName"),
            dict(name='TargetResourceGroup', help='Resource group to create the VM in. Must already exist.',
                 decl="[Parameter(Mandatory)]\n    [string]$TargetResourceGroup"),
            dict(name='Location', help='Azure region.',
                 decl="[Parameter(Mandatory)]\n    [string]$Location"),
            dict(name='VmSize', help='VM size SKU. This is the main cost driver.',
                 decl="[string]$VmSize = 'Standard_D2s_v5'"),
            dict(name='Image', help='Image URN, e.g. Win2022Datacenter or a full publisher:offer:sku:version.',
                 decl="[string]$Image = 'Win2022Datacenter'"),
            dict(name='SubnetId', help='Resource id of the subnet to attach the VM to.',
                 decl="[Parameter(Mandatory)]\n    [string]$SubnetId"),
            dict(name='AdminCredential', help='Local administrator credential for the new VM. Prompted for if omitted; never accepted as plaintext.',
                 decl="[System.Management.Automation.PSCredential]\n    [System.Management.Automation.Credential()]\n    $AdminCredential"),
            dict(name='AllowedVmSize', help='Permitted size SKUs. A size outside this list is refused, so a typo cannot deploy an expensive VM.',
                 decl="[string[]]$AllowedVmSize = @('Standard_B2s','Standard_B2ms','Standard_D2s_v5','Standard_D4s_v5','Standard_E2s_v5')")],
    perms='Virtual Machine Contributor plus Network Contributor on the target scope.',
    actionVerb='Provision Azure VM',
    reason='New VM provisioning',
    rollback='Remove-AzVM plus deletion of the NIC, disk and any public IP. Deleting a VM does not '
             'delete those by default - budget for cleaning them up too.',
    notes='The admin credential is taken as a PSCredential and never as a plaintext string. If it '
          'is omitted PowerShell prompts, which keeps the secret out of the command line and out of '
          'shell history.',
    examples=[("-NewVMName APP03 -TargetResourceGroup rg-prod -Location uaenorth -SubnetId '/subscriptions/.../subnets/app'",
               'REQUEST mode - validates the size against the allow-list and raises an approval.'),
              ("-NewVMName APP03 -TargetResourceGroup rg-prod -Location uaenorth -SubnetId '...' -ApprovalReference APR-...",
               'Deploys the approved VM.')],
    discover=SELECT_SUB + """
if ($AllowedVmSize -and $AllowedVmSize -notcontains $VmSize) {
    throw ('Refusing to provision: size "{0}" is not in the allowed list ({1}).' -f $VmSize, ($AllowedVmSize -join ', '))
}

$rg = Get-AzResourceGroup -Name $TargetResourceGroup -ErrorAction SilentlyContinue
if (-not $rg) { throw ('Resource group {0} does not exist. Create it first.' -f $TargetResourceGroup) }

if (Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $NewVMName -ErrorAction SilentlyContinue) {
    throw ('A VM named {0} already exists in {1}. Refusing to provision a duplicate.' -f $NewVMName, $TargetResourceGroup)
}

# Surface the size's actual specification so an approver sees what they are
# approving, rather than an opaque SKU string.
$sizeInfo = Get-AzVMSize -Location $Location | Where-Object Name -eq $VmSize | Select-Object -First 1

$results.Add([PSCustomObject]@{
    Name          = $NewVMName
    Id            = $NewVMName
    ResourceGroup = $TargetResourceGroup
    Location      = $Location
    VmSize        = $VmSize
    Cores         = if ($sizeInfo) { $sizeInfo.NumberOfCores } else { $null }
    MemoryMB      = if ($sizeInfo) { $sizeInfo.MemoryInMB } else { $null }
    MaxDataDisks  = if ($sizeInfo) { $sizeInfo.MaxDataDiskCount } else { $null }
    Image         = $Image
    SubnetId      = $SubnetId
    CostNote      = 'VM size is the primary monthly cost driver - confirm the SKU before approving'
})
""",
    act="""
if (-not $AdminCredential) {
    throw 'An -AdminCredential is required to create the VM. It is never accepted as a plaintext string.'
}

$nicName = '{0}-nic' -f $item.Name
$nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $item.ResourceGroup `
    -Location $item.Location -SubnetId $item.SubnetId -Force -ErrorAction Stop

$vmConfig = New-AzVMConfig -VMName $item.Name -VMSize $item.VmSize |
    Set-AzVMOperatingSystem -Windows -ComputerName $item.Name -Credential $AdminCredential |
    Set-AzVMSourceImage -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' `
        -Skus '2022-datacenter-azure-edition' -Version 'latest' |
    Add-AzVMNetworkInterface -Id $nic.Id

New-AzVM -ResourceGroupName $item.ResourceGroup -Location $item.Location -VM $vmConfig -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'VM provisioned: {0} ({1} cores, {2}MB RAM) in {3}' -f $item.VmSize, $item.Cores, $item.MemoryMB, $item.Location)
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Provisioned'; Detail = $item.VmSize; Succeeded = $true })
"""),

7: dict(
    file='Reset-AzEntraUserPassword',
    modules=['Az.Accounts', 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Users'],
    synopsis='Resets an Entra ID user password after ticket-verified approval.',
    desc='Sets a new password for a user and forces a change at next sign-in. Identity operations '
         'are the highest-value target in any estate, so this refuses to run without an approval '
         'reference AND a ticket reference - the workbook guardrail requires the requester\'s '
         'identity to be verified through ITSM before the agent executes.',
    params=[
            dict(name='UserPrincipalName', help='User(s) whose password to reset.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$UserPrincipalName"),
            dict(name='ForceChangeAtNextSignIn', help='Require the user to change the password at next sign-in. On by default; use -ForceChangeAtNextSignIn:$false only with a documented reason.',
                 decl="[bool]$ForceChangeAtNextSignIn = $true"),
            dict(name='RequireTicketReference', help='Refuse to execute without a -TicketReference. On by default because this row is identity-sensitive.',
                 decl="[bool]$RequireTicketReference = $true")],
    perms='Microsoft Graph User.ReadWrite.All plus a directory role permitting password reset (Password Administrator or higher). Resetting an administrator requires Global Administrator.',
    actionVerb='Reset user password',
    reason='Password reset (ITSM-verified)',
    rollback='NONE - the previous password cannot be restored. The user must complete a new reset '
             'if this was done in error.',
    notes='The generated password is written ONCE to the console for the operator to communicate '
          'through the agreed channel. It is deliberately NOT written to the log file or the '
          'approval artifact, both of which are scrubbed of credential-shaped strings.',
    examples=[("-UserPrincipalName user@contoso.com -TicketReference INC0012345",
               'REQUEST mode - raises an approval referencing the ticket. Changes nothing.'),
              ("-UserPrincipalName user@contoso.com -TicketReference INC0012345 -ApprovalReference APR-...",
               'Performs the approved reset.')],
    discover="""
Connect-MgGraph -Scopes 'User.ReadWrite.All' -NoWelcome -ErrorAction Stop

if ($RequireTicketReference -and -not $TicketReference) {
    throw 'A -TicketReference is required for a password reset. Verify the requester''s identity through ITSM first.'
}

foreach ($upn in $UserPrincipalName) {
    $u = Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName,AccountEnabled,UserType,OnPremisesSyncEnabled -ErrorAction Stop

    # A synced account's password is mastered on-premises; resetting it in the
    # cloud either fails or is overwritten at the next sync.
    if ($u.OnPremisesSyncEnabled) {
        throw ('{0} is synchronised from on-premises AD. Reset the password in AD, not in Entra ID.' -f $upn)
    }

    $results.Add([PSCustomObject]@{
        Name          = $u.UserPrincipalName
        Id            = $u.Id
        DisplayName   = $u.DisplayName
        AccountEnabled= $u.AccountEnabled
        UserType      = $u.UserType
        Ticket        = $TicketReference
        ForceChange   = $ForceChangeAtNextSignIn
    })
}
""",
    act="""
# Generated in-process and never persisted. Write-AutomationLog scrubs
# credential-shaped strings, so this is deliberately shown only on the console.
Add-Type -AssemblyName System.Web
$newPassword = [System.Web.Security.Membership]::GeneratePassword(20, 5)

$passwordProfile = @{ Password = $newPassword; ForceChangePasswordNextSignIn = $item.ForceChange }
Update-MgUser -UserId $item.Id -PasswordProfile $passwordProfile -ErrorAction Stop

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Password reset completed. Ticket={0} Approval={1} ForceChange={2}. The password itself is NOT logged.' -f
    $TicketReference, $ApprovalReference, $item.ForceChange)

$banner = @(
    ''
    ('  New password for {0}:' -f $item.Name)
    ('  {0}' -f $newPassword)
    '  Communicate this through the agreed channel. It is shown once and is not stored.'
    ''
) -join [Environment]::NewLine

# Information stream, not the success pipeline: the secret reaches the
# operator's console but never lands in $result, a CSV, or a JSON export.
Write-Information $banner -InformationAction Continue

$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'PasswordReset'
    Detail = ('ticket {0}; force change {1}' -f $TicketReference, $item.ForceChange); Succeeded = $true })
"""),

8: dict(
    file='Set-AzEntraUserAccountState',
    modules=['Az.Accounts', 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Users'],
    synopsis='Enables or disables an Entra ID user account after ticket-verified approval.',
    desc='Blocks or restores sign-in for a user. Disabling an account locks a person out of every '
         'system federated to Entra ID, so this requires both an approval reference and a ticket '
         'reference, and refuses outright on accounts holding privileged directory roles unless '
         'that is explicitly acknowledged.',
    params=[
            dict(name='UserPrincipalName', help='User(s) to act on.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$UserPrincipalName"),
            dict(name='Operation', help='Disable blocks sign-in; Enable restores it.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Disable','Enable')]\n    [string]$Operation"),
            dict(name='AllowPrivilegedAccount', help='Permit acting on an account that holds a directory role. Off by default.',
                 decl="[switch]$AllowPrivilegedAccount"),
            dict(name='RevokeSessions', help='Also revoke existing refresh tokens so current sessions end immediately.',
                 decl="[switch]$RevokeSessions")],
    perms='Microsoft Graph User.ReadWrite.All and RoleManagement.Read.Directory.',
    actionVerb='Change account sign-in state',
    reason='Account lock/unlock (ITSM-verified)',
    rollback='Re-run with the opposite -Operation. Revoked sessions are not restored - the user '
             'simply signs in again.',
    notes='Disabling the account does not end sessions already in progress; an issued access token '
          'remains valid until it expires. Use -RevokeSessions when the intent is to cut access now '
          'rather than prevent the next sign-in.',
    examples=[("-UserPrincipalName leaver@contoso.com -Operation Disable -TicketReference INC0012345 -RevokeSessions",
               'REQUEST mode - raises an approval to block sign-in and end current sessions.'),
              ("-UserPrincipalName leaver@contoso.com -Operation Disable -TicketReference INC0012345 -ApprovalReference APR-...",
               'Performs the approved account lock.')],
    discover="""
Connect-MgGraph -Scopes 'User.ReadWrite.All','RoleManagement.Read.Directory' -NoWelcome -ErrorAction Stop

if (-not $TicketReference) {
    throw 'A -TicketReference is required. Account lock is ticket-driven with requester verification.'
}

foreach ($upn in $UserPrincipalName) {
    $u = Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName,AccountEnabled,UserType -ErrorAction Stop

    $wanted = ($Operation -eq 'Enable')
    if ($u.AccountEnabled -eq $wanted) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $upn `
            -Message ('Skipped - AccountEnabled is already {0}' -f $wanted)
        continue
    }

    # Locking a privileged account can remove the last route into the tenant.
    $roles = @()
    try {
        $roles = @(Get-MgUserMemberOf -UserId $u.Id -All -ErrorAction Stop |
            Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
            ForEach-Object { $_.AdditionalProperties.displayName })
    } catch {
        Write-Verbose ('Could not enumerate directory roles for {0}' -f $upn)
    }
    if ($roles.Count -gt 0 -and -not $AllowPrivilegedAccount) {
        throw ('{0} holds directory role(s): {1}. Refusing without -AllowPrivilegedAccount.' -f $upn, ($roles -join ', '))
    }

    $results.Add([PSCustomObject]@{
        Name            = $u.UserPrincipalName
        Id              = $u.Id
        DisplayName     = $u.DisplayName
        CurrentEnabled  = $u.AccountEnabled
        DesiredEnabled  = $wanted
        UserType        = $u.UserType
        DirectoryRoles  = ($roles -join '; ')
        Privileged      = ($roles.Count -gt 0)
        Ticket          = $TicketReference
        RevokeSessions  = [bool]$RevokeSessions
    })
}
""",
    act="""
Update-MgUser -UserId $item.Id -AccountEnabled:$item.DesiredEnabled -ErrorAction Stop

$revoked = $false
if ($RevokeSessions -and -not $item.DesiredEnabled) {
    try {
        Revoke-MgUserSignInSession -UserId $item.Id -ErrorAction Stop | Out-Null
        $revoked = $true
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
            -Message ('Account disabled but session revocation failed: {0}' -f $_.Exception.Message)
    }
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'AccountEnabled {0} -> {1}. Sessions revoked: {2}. Ticket={3}' -f
    $item.CurrentEnabled, $item.DesiredEnabled, $revoked, $TicketReference)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $Operation
    Detail = ('enabled={0}; sessions revoked={1}' -f $item.DesiredEnabled, $revoked); Succeeded = $true })
"""),

9: dict(
    file='Clear-AzVmTempPath',
    modules=['Az.Accounts', 'Az.Compute'],
    synopsis='Reclaims disk space on Azure VMs by clearing whitelisted temporary paths.',
    desc='Runs a cleanup inside the guest through the Azure VM run-command, deleting files only '
         'from paths on an explicit whitelist. The whitelist is the entire safety model: the script '
         'refuses to run without one and rejects any path not on it, because a cleanup script with '
         'an open path parameter is a deletion tool.',
    params=[SUB, RG,
            dict(name='VMName', help='Virtual machines to clean.',
                 decl="[string[]]$VMName"),
            dict(name='CleanupPath', help='Paths to clear. Every one must appear in -AllowedPath or the script refuses.',
                 decl="[string[]]$CleanupPath = @('C:\\\\Windows\\\\Temp','C:\\\\Users\\\\*\\\\AppData\\\\Local\\\\Temp')"),
            dict(name='AllowedPath', help='The whitelist. A path outside this list is never cleaned, whatever -CleanupPath says.',
                 decl="[string[]]$AllowedPath = @('C:\\\\Windows\\\\Temp','C:\\\\Users\\\\*\\\\AppData\\\\Local\\\\Temp','C:\\\\Windows\\\\SoftwareDistribution\\\\Download','C:\\\\Windows\\\\Logs\\\\CBS')"),
            dict(name='OlderThanDays', help='Only delete files last written before this many days ago.',
                 decl="[ValidateRange(0,3650)]\n    [int]$OlderThanDays = 7"),
            dict(name='MinimumFreeGB', help='Only clean VMs whose OS disk free space is below this.',
                 decl="[ValidateRange(0,10000)]\n    [int]$MinimumFreeGB = 10")],
    perms='Virtual Machine Contributor (run-command requires it). The guest cleanup runs as SYSTEM.',
    actionVerb='Clear temporary files',
    rollback='NONE - deleted files are not recoverable. The path whitelist and the age filter exist '
             'because there is no undo.',
    notes='Runs through Invoke-AzVMRunCommand, so it needs the Azure VM agent healthy on the guest. '
          'The generated guest script deletes files only, never directories, and skips anything '
          'currently locked rather than forcing.',
    examples=[("-ResourceGroupName rg-prod -OlderThanDays 7",
               'Cleans standard temp paths on VMs low on space.'),
              ("-VMName APP01 -CleanupPath 'C:\\\\Windows\\\\Temp' -WhatIf",
               'Shows what would be cleaned on one VM.')],
    discover=SELECT_SUB + """
if (-not $AllowedPath -or $AllowedPath.Count -eq 0) {
    throw 'Refusing to run: -AllowedPath is empty. The whitelist is this script''s only safety control.'
}

# Every requested path must be on the whitelist. No exceptions, no override.
foreach ($p in $CleanupPath) {
    if ($AllowedPath -notcontains $p) {
        throw ('Refusing to clean "{0}" - it is not in -AllowedPath. Add it deliberately if it is genuinely safe.' -f $p)
    }
}
Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    'Path whitelist verified: {0} path(s) approved for cleanup' -f $CleanupPath.Count)

$vms = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ -Status } }
       else                    { Get-AzVM -Status }
if ($VMName) { $vms = $vms | Where-Object { $VMName -contains $_.Name } }

foreach ($vm in $vms) {
    if (($vm.PowerState -replace '^VM ', '') -ne 'running') {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $vm.Name `
            -Message 'Skipped - VM is not running'
        continue
    }
    $results.Add([PSCustomObject]@{
        Name          = $vm.Name
        Id            = $vm.Id
        ResourceGroup = $vm.ResourceGroupName
        Location      = $vm.Location
        PowerState    = ($vm.PowerState -replace '^VM ', '')
        Paths         = ($CleanupPath -join '; ')
        OlderThanDays = $OlderThanDays
        MinimumFreeGB = $MinimumFreeGB
    })
}
""",
    act="""
# Built here rather than shipped as a file so the whitelist cannot drift
# between what was validated above and what actually runs in the guest.
$guestScript = @(
    '$ErrorActionPreference = ''Continue'''
    ('$paths = @({0})' -f (($CleanupPath | ForEach-Object { "'$_'" }) -join ','))
    ('$cutoff = (Get-Date).AddDays(-{0})' -f $OlderThanDays)
    ('$minFreeGB = {0}' -f $MinimumFreeGB)
    '$drive = Get-PSDrive C'
    '$freeBefore = [math]::Round($drive.Free / 1GB, 2)'
    'if ($freeBefore -gt $minFreeGB) {'
    '    Write-Output ("SKIPPED: {0}GB free is above the {1}GB threshold" -f $freeBefore, $minFreeGB)'
    '    exit 0'
    '}'
    '$removed = 0; $bytes = 0'
    'foreach ($p in $paths) {'
    '    foreach ($resolved in (Resolve-Path -Path $p -ErrorAction SilentlyContinue)) {'
    '        Get-ChildItem -LiteralPath $resolved -File -Recurse -Force -ErrorAction SilentlyContinue |'
    '            Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {'
    '                try { $sz = $_.Length; Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop'
    '                      $removed++; $bytes += $sz } catch { }'
    '            }'
    '    }'
    '}'
    '$freeAfter = [math]::Round((Get-PSDrive C).Free / 1GB, 2)'
    'Write-Output ("REMOVED {0} file(s), {1}MB. Free {2}GB -> {3}GB" -f $removed, [math]::Round($bytes/1MB,1), $freeBefore, $freeAfter)'
) -join "`n"

$tmp = [System.IO.Path]::GetTempFileName() + '.ps1'
Set-Content -LiteralPath $tmp -Value $guestScript -Encoding UTF8

try {
    $out = Invoke-AzVMRunCommand -ResourceGroupName $item.ResourceGroup -VMName $item.Name `
        -CommandId 'RunPowerShellScript' -ScriptPath $tmp -ErrorAction Stop
    $msg = ($out.Value | Where-Object Code -like '*StdOut*' | Select-Object -First 1 -Expand Message)
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Cleanup result: {0}' -f ($msg -replace "`n", ' ').Trim())
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Cleaned'; Detail = ($msg -replace "`n", ' ').Trim(); Succeeded = $true })
"""),

11: dict(
    file='Get-AzAvdUtilizationReport',
    modules=['Az.Accounts', 'Az.DesktopVirtualization'],
    synopsis='Reports Azure Virtual Desktop host pool utilisation and session activity.',
    desc='For each host pool, reports session host availability, active and disconnected session '
         'counts, and hosts in drain mode. Disconnected sessions are reported separately from '
         'active ones, because a pool that looks busy is often holding sessions nobody is using.',
    params=[SUB, RG,
            dict(name='HostPoolName', help='Limit to specific host pools.',
                 decl="[string[]]$HostPoolName")],
    perms='Desktop Virtualization Reader on the target scope.',
    examples=[("-OutputFormat HTML", 'Utilisation report for every host pool.'),
              ("-HostPoolName hp-prod -OutputFormat JSON", 'One pool as JSON.')],
    discover=SELECT_SUB + """
$pools = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzWvdHostPool -ResourceGroupName $_ } }
         else                    { Get-AzWvdHostPool }
if ($HostPoolName) { $pools = $pools | Where-Object { $HostPoolName -contains $_.Name } }

foreach ($pool in $pools) {
    $rg = ($pool.Id -split '/')[4]
    $hosts = @(Get-AzWvdSessionHost -ResourceGroupName $rg -HostPoolName $pool.Name -ErrorAction SilentlyContinue)
    $sessions = @(Get-AzWvdUserSession -ResourceGroupName $rg -HostPoolName $pool.Name -ErrorAction SilentlyContinue)

    $available = @($hosts | Where-Object { $_.Status -eq 'Available' })
    $draining  = @($hosts | Where-Object { $_.AllowNewSession -eq $false })
    $active    = @($sessions | Where-Object { $_.SessionState -eq 'Active' })
    $disc      = @($sessions | Where-Object { $_.SessionState -eq 'Disconnected' })

    $issues = @()
    if ($available.Count -eq 0 -and $hosts.Count -gt 0) { $issues += 'no session hosts available' }
    if ($draining.Count -gt 0)                          { $issues += ('{0} host(s) in drain mode' -f $draining.Count) }
    if ($disc.Count -gt $active.Count -and $disc.Count -gt 0) { $issues += 'more disconnected than active sessions' }

    $results.Add([PSCustomObject]@{
        Name              = $pool.Name
        Id                = $pool.Id
        ResourceGroup     = $rg
        HostPoolType      = "$($pool.HostPoolType)"
        LoadBalancerType  = "$($pool.LoadBalancerType)"
        MaxSessionLimit   = $pool.MaxSessionLimit
        SessionHostsTotal = $hosts.Count
        SessionHostsAvailable = $available.Count
        SessionHostsDraining  = $draining.Count
        ActiveSessions    = $active.Count
        DisconnectedSessions = $disc.Count
        TotalSessions     = $sessions.Count
        UtilisationPercent = if ($pool.MaxSessionLimit -gt 0 -and $hosts.Count -gt 0) {
                                 [math]::Round(($sessions.Count / ($pool.MaxSessionLimit * $hosts.Count)) * 100, 1)
                             } else { $null }
        Status            = if ($issues.Count) { 'Warning' } else { 'OK' }
        Issues            = ($issues -join '; ')
    })
}
"""),

13: dict(
    file='Get-AzCostAnomalyReport',
    modules=['Az.Accounts', 'Az.CostManagement'],
    synopsis='Detects Azure cost spikes by comparing recent spend against a baseline.',
    desc='Queries Cost Management for daily cost by service over the lookback window and flags any '
         'service whose recent average exceeds its baseline average by more than the threshold. '
         'The workbook guardrail specifies alerting on spikes above 20%, which is the default here.',
    params=[SUB,
            dict(name='LookbackDays', help='Total window to query.',
                 decl="[ValidateRange(7,365)]\n    [int]$LookbackDays = 30"),
            dict(name='RecentDays', help='How many recent days form the comparison period.',
                 decl="[ValidateRange(1,30)]\n    [int]$RecentDays = 3"),
            dict(name='SpikeThresholdPercent', help='Percentage increase over baseline at which a service is flagged.',
                 decl="[ValidateRange(1,1000)]\n    [int]$SpikeThresholdPercent = 20"),
            dict(name='MinimumDailyCost', help='Ignore services whose daily cost is below this. Stops trivial amounts generating noise.',
                 decl="[double]$MinimumDailyCost = 5")],
    perms='Cost Management Reader on the subscription.',
    notes='Cost Management data lags actual usage by up to 24 hours, and the most recent day is '
          'usually incomplete. -RecentDays defaults to 3 so a partial final day cannot on its own '
          'trigger a false spike.',
    examples=[("-SpikeThresholdPercent 20",
               'Flags services whose recent spend is 20% above baseline.'),
              ("-LookbackDays 60 -RecentDays 7 -OutputFormat HTML",
               'Compares the last week against a two-month baseline.')],
    discover=SELECT_SUB + """
$end   = (Get-Date).Date.AddDays(-1)       # yesterday; today is always partial
$start = $end.AddDays(-$LookbackDays)

$scope = '/subscriptions/{0}' -f (Get-AzContext).Subscription.Id
$query = @{
    type       = 'ActualCost'
    timeframe  = 'Custom'
    timePeriod = @{ from = $start.ToString('yyyy-MM-dd'); to = $end.ToString('yyyy-MM-dd') }
    dataset    = @{
        granularity = 'Daily'
        aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
        grouping    = @(@{ type = 'Dimension'; name = 'ServiceName' })
    }
}

$resp = Invoke-AzRestMethod -Path ("{0}/providers/Microsoft.CostManagement/query?api-version=2023-03-01" -f $scope) `
    -Method POST -Payload ($query | ConvertTo-Json -Depth 10) -ErrorAction Stop

if ($resp.StatusCode -ge 400) {
    throw ('Cost Management query failed with HTTP {0}: {1}' -f $resp.StatusCode, $resp.Content)
}

$data = ($resp.Content | ConvertFrom-Json).properties
$cols = $data.columns.name
$iCost = [array]::IndexOf($cols, 'Cost')
$iDate = [array]::IndexOf($cols, 'UsageDate')
$iSvc  = [array]::IndexOf($cols, 'ServiceName')

$recentCutoff = [int]$end.AddDays(-$RecentDays + 1).ToString('yyyyMMdd')

$byService = @{}
foreach ($row in $data.rows) {
    $svc  = $row[$iSvc]
    $cost = [double]$row[$iCost]
    $date = [int]$row[$iDate]
    if (-not $byService.ContainsKey($svc)) { $byService[$svc] = @{ Recent = @(); Baseline = @() } }
    if ($date -ge $recentCutoff) { $byService[$svc].Recent   += $cost }
    else                         { $byService[$svc].Baseline += $cost }
}

foreach ($svc in $byService.Keys) {
    $r = $byService[$svc].Recent
    $b = $byService[$svc].Baseline
    if ($r.Count -eq 0 -or $b.Count -eq 0) { continue }

    $recentAvg   = ($r | Measure-Object -Average).Average
    $baselineAvg = ($b | Measure-Object -Average).Average
    if ($recentAvg -lt $MinimumDailyCost) { continue }
    if ($baselineAvg -le 0) { continue }

    $pct = [math]::Round((($recentAvg - $baselineAvg) / $baselineAvg) * 100, 1)
    if ($pct -lt $SpikeThresholdPercent) { continue }

    $results.Add([PSCustomObject]@{
        Name           = $svc
        Id             = $svc
        RecentAvgDaily = [math]::Round($recentAvg, 2)
        BaselineAvgDaily = [math]::Round($baselineAvg, 2)
        IncreasePercent= $pct
        IncreaseDaily  = [math]::Round($recentAvg - $baselineAvg, 2)
        ProjectedMonthlyDelta = [math]::Round(($recentAvg - $baselineAvg) * 30, 2)
        RecentDays     = $RecentDays
        BaselineDays   = $b.Count
        Status         = 'Spike'
    })
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $svc -Message (
        'Cost spike {0}% - {1}/day vs {2}/day baseline' -f $pct, [math]::Round($recentAvg,2), [math]::Round($baselineAvg,2))
}
"""),

14: dict(
    file='Set-AzVmssCapacity',
    modules=['Az.Accounts', 'Az.Compute'],
    synopsis='Adjusts VM Scale Set capacity within configured minimum and maximum bounds.',
    desc='Scales a VM Scale Set in or out to a requested instance count, refusing any value outside '
         'the configured floor and ceiling. The bounds are the guardrail: an unbounded scale-out is '
         'a cost incident and an unbounded scale-in is an outage.',
    params=[SUB, RG,
            dict(name='VmssName', help='Scale set(s) to adjust.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$VmssName"),
            dict(name='DesiredCapacity', help='Target instance count.',
                 decl="[Parameter(Mandatory)]\n    [ValidateRange(0,1000)]\n    [int]$DesiredCapacity"),
            dict(name='MinCapacity', help='Floor. A request below this is refused.',
                 decl="[ValidateRange(0,1000)]\n    [int]$MinCapacity = 2"),
            dict(name='MaxCapacity', help='Ceiling. A request above this is refused.',
                 decl="[ValidateRange(1,1000)]\n    [int]$MaxCapacity = 10")],
    perms='Virtual Machine Contributor on the scale set.',
    actionVerb='Set VMSS capacity',
    rollback='Re-run with the previous capacity, which is recorded in the audit log before the '
             'change is applied.',
    notes='Scaling in terminates instances. If the workload is not stateless, drain connections '
          'first - this script does not do that, and cannot know which instances are safe to remove.',
    examples=[("-VmssName vmss-web -DesiredCapacity 6 -ResourceGroupName rg-prod",
               'Scales the set to 6 instances if that is within bounds.'),
              ("-VmssName vmss-web -DesiredCapacity 20 -MaxCapacity 10",
               'Refused - the request exceeds the configured ceiling.')],
    discover=SELECT_SUB + """
if ($MinCapacity -gt $MaxCapacity) {
    throw ('MinCapacity ({0}) cannot exceed MaxCapacity ({1}).' -f $MinCapacity, $MaxCapacity)
}
if ($DesiredCapacity -lt $MinCapacity -or $DesiredCapacity -gt $MaxCapacity) {
    throw ('Refusing: desired capacity {0} is outside the configured bounds {1}-{2}.' -f
           $DesiredCapacity, $MinCapacity, $MaxCapacity)
}

foreach ($name in $VmssName) {
    $vmss = if ($ResourceGroupName) {
                Get-AzVmss -ResourceGroupName $ResourceGroupName[0] -VMScaleSetName $name -ErrorAction Stop
            } else {
                Get-AzVmss | Where-Object Name -eq $name | Select-Object -First 1
            }
    if (-not $vmss) { throw ('Scale set {0} not found.' -f $name) }

    $current = $vmss.Sku.Capacity
    if ($current -eq $DesiredCapacity) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $name `
            -Message ('Skipped - already at capacity {0}' -f $current)
        continue
    }

    $results.Add([PSCustomObject]@{
        Name            = $vmss.Name
        Id              = $vmss.Id
        ResourceGroup   = $vmss.ResourceGroupName
        Location        = $vmss.Location
        SkuName         = $vmss.Sku.Name
        CurrentCapacity = $current
        DesiredCapacity = $DesiredCapacity
        Direction       = if ($DesiredCapacity -gt $current) { 'scale out' } else { 'SCALE IN (terminates instances)' }
        Bounds          = ('{0}-{1}' -f $MinCapacity, $MaxCapacity)
    })
}
""",
    act="""
$vmss = Get-AzVmss -ResourceGroupName $item.ResourceGroup -VMScaleSetName $item.Name -ErrorAction Stop
$vmss.Sku.Capacity = $item.DesiredCapacity
Update-AzVmss -ResourceGroupName $item.ResourceGroup -Name $item.Name -VirtualMachineScaleSet $vmss -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Capacity {0} -> {1} ({2}), within bounds {3}' -f
    $item.CurrentCapacity, $item.DesiredCapacity, $item.Direction, $item.Bounds)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'CapacitySet'
    Detail = ('{0} -> {1}' -f $item.CurrentCapacity, $item.DesiredCapacity); Succeeded = $true })
"""),

15: dict(
    file='Remove-AzNsgRule',
    modules=['Az.Accounts', 'Az.Network'],
    synopsis='Audits network security group rules and removes approved candidates.',
    desc='Audits NSG rules for the patterns worth questioning - any-source inbound, wide port '
         'ranges, rules shadowed by a higher-priority rule, and rules with no matching traffic - '
         'and produces a candidate list. Deleting an NSG rule can sever production traffic, and '
         'only the network owner knows which flows are real, so removal is gated behind both '
         'approval and an explicit -Execute.',
    params=[SUB, RG,
            dict(name='NetworkSecurityGroupName', help='Limit to specific NSGs.',
                 decl="[string[]]$NetworkSecurityGroupName"),
            dict(name='FlagAnySource', help='Flag inbound Allow rules whose source is Any/Internet.',
                 decl="[bool]$FlagAnySource = $true"),
            dict(name='FlagWidePortRange', help='Flag rules spanning more than this many ports.',
                 decl="[ValidateRange(1,65535)]\n    [int]$FlagWidePortRange = 100")],
    minage=0,
    perms='Network Contributor on the NSG.',
    actionVerb='Remove NSG rule',
    reason='NSG rule cleanup',
    rollback='Re-create the rule from the pre-deletion export this script writes. The export '
             'captures the full rule definition including priority, which is what makes restoration '
             'possible.',
    notes='This script CANNOT know whether a rule is still needed. It surfaces candidates and the '
          'reason each was flagged; deciding which are genuinely safe to delete requires a network '
          'owner who knows the traffic flows. That judgement is deliberately not automated.',
    examples=[("-ResourceGroupName rg-net",
               'REPORT ONLY. Audits every NSG and raises an approval with the candidate list.'),
              ("-ResourceGroupName rg-net -ApprovalReference APR-... -Execute -ProtectedList .\\keep-rules.txt",
               'Removes the approved rules, excluding anything on the protected list.')],
    discover=SELECT_SUB + """
$nsgs = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzNetworkSecurityGroup -ResourceGroupName $_ } }
        else                    { Get-AzNetworkSecurityGroup }
if ($NetworkSecurityGroupName) { $nsgs = $nsgs | Where-Object { $NetworkSecurityGroupName -contains $_.Name } }

foreach ($nsg in $nsgs) {
    $rules = @($nsg.SecurityRules | Sort-Object Priority)

    foreach ($rule in $rules) {
        $flags = @()

        if ($FlagAnySource -and $rule.Direction -eq 'Inbound' -and $rule.Access -eq 'Allow') {
            $srcs = @($rule.SourceAddressPrefix) + @($rule.SourceAddressPrefixes)
            if ($srcs | Where-Object { $_ -in @('*','Internet','0.0.0.0/0') }) {
                $flags += 'inbound Allow from Any/Internet'
            }
        }

        foreach ($pr in (@($rule.DestinationPortRange) + @($rule.DestinationPortRanges))) {
            if (-not $pr) { continue }
            if ($pr -eq '*') { $flags += 'all destination ports'; continue }
            if ($pr -match '^(\\d+)-(\\d+)$') {
                $span = [int]$Matches[2] - [int]$Matches[1]
                if ($span -gt $FlagWidePortRange) { $flags += ('port range spans {0} ports' -f $span) }
            }
        }

        # Shadowed: an earlier rule with the same direction already matches
        # everything this one would, so this rule can never take effect.
        $shadow = $rules | Where-Object {
            $_.Priority -lt $rule.Priority -and
            $_.Direction -eq $rule.Direction -and
            $_.SourceAddressPrefix -eq '*' -and
            $_.DestinationAddressPrefix -eq '*' -and
            $_.DestinationPortRange -eq '*' -and
            $_.Protocol -eq '*'
        } | Select-Object -First 1
        if ($shadow) { $flags += ('shadowed by higher-priority rule {0} ({1})' -f $shadow.Name, $shadow.Priority) }

        if ($flags.Count -eq 0) { continue }

        $results.Add([PSCustomObject]@{
            Name          = ('{0} / {1}' -f $nsg.Name, $rule.Name)
            Id            = $rule.Name
            NsgName       = $nsg.Name
            ResourceGroup = $nsg.ResourceGroupName
            RuleName      = $rule.Name
            Priority      = $rule.Priority
            Direction     = "$($rule.Direction)"
            Access        = "$($rule.Access)"
            Protocol      = "$($rule.Protocol)"
            SourcePrefix  = ((@($rule.SourceAddressPrefix) + @($rule.SourceAddressPrefixes)) -join ',')
            DestPrefix    = ((@($rule.DestinationAddressPrefix) + @($rule.DestinationAddressPrefixes)) -join ',')
            DestPorts     = ((@($rule.DestinationPortRange) + @($rule.DestinationPortRanges)) -join ',')
            Flags         = ($flags -join '; ')
            AttachedTo    = ((@($nsg.Subnets.Id) + @($nsg.NetworkInterfaces.Id) | ForEach-Object { ($_ -split '/')[-1] }) -join '; ')
            OwnerDecision = 'A network owner must confirm no live traffic depends on this rule'
        })
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $nsg.Name, $rule.Name) `
            -Message ($flags -join '; ')
    }
}
""",
    backup="""
# Export the full rule definition before deleting it. This export is the only
# thing that makes the deletion reversible.
$exportDir = Join-Path $env:ProgramData 'ITAutomation\\Rollback'
if (-not (Test-Path -LiteralPath $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }
$exportPath = Join-Path $exportDir ('nsgrule-{0}-{1}-{2}.json' -f $item.NsgName, $item.RuleName, (Get-Date -Format 'yyyyMMdd-HHmmss'))

$nsgObj = Get-AzNetworkSecurityGroup -ResourceGroupName $item.ResourceGroup -Name $item.NsgName -ErrorAction Stop
$ruleObj = $nsgObj.SecurityRules | Where-Object Name -eq $item.RuleName | Select-Object -First 1
$ruleObj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $exportPath -Encoding UTF8

Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Rule definition exported to {0} - this is the restore path' -f $exportPath)
""",
    act="""
$nsgObj = Get-AzNetworkSecurityGroup -ResourceGroupName $item.ResourceGroup -Name $item.NsgName -ErrorAction Stop
Remove-AzNetworkSecurityRuleConfig -Name $item.RuleName -NetworkSecurityGroup $nsgObj -ErrorAction Stop | Out-Null
Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsgObj -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'NSG rule REMOVED: {0} (priority {1}). Restore from {2}' -f $item.RuleName, $item.Priority, $exportPath)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'RuleRemoved'
    Detail = ('priority {0}; export {1}' -f $item.Priority, $exportPath); Succeeded = $true })
"""),

16: dict(
    file='Remove-AzUnattachedDisk',
    modules=['Az.Accounts', 'Az.Compute'],
    synopsis='Deletes Azure managed disks that are unattached beyond a minimum age.',
    desc='Finds managed disks in the Unattached state and deletes them after approval. A snapshot '
         'of each disk is taken and retained before deletion, so an orphaned disk that turns out to '
         'have mattered is still recoverable.',
    params=[SUB, RG,
            dict(name='ExcludeTagKey', help='Disks carrying this tag are never deleted.',
                 decl="[string]$ExcludeTagKey = 'AutoOps:DoNotDelete'"),
            dict(name='SkipSnapshot', help='Skip the pre-deletion snapshot. Strongly discouraged - the snapshot is the only recovery path.',
                 decl="[switch]$SkipSnapshot")],
    minage=30,
    perms='Contributor on the resource group holding the disks.',
    actionVerb='Delete unattached managed disk',
    reason='Orphaned managed disk cleanup',
    rollback='Create a new disk from the pre-deletion snapshot this script retains. Once both the '
             'disk and its snapshot are gone the data is unrecoverable.',
    notes='Azure does not record when a disk became unattached, so age is measured from the disk\'s '
          'creation time. A recently created but already-orphaned disk will therefore not be '
          'proposed until it ages past the threshold - deliberately conservative.',
    examples=[("-MinimumAgeDays 30",
               'REPORT ONLY. Lists unattached disks older than 30 days and raises an approval.'),
              ("-MinimumAgeDays 30 -ApprovalReference APR-... -Execute",
               'Deletes the approved disks, snapshotting each first.')],
    discover=SELECT_SUB + """
$disks = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzDisk -ResourceGroupName $_ } }
         else                    { Get-AzDisk }

foreach ($d in $disks) {
    if ($d.DiskState -ne 'Unattached') { continue }

    if ($ExcludeTagKey -and $d.Tags -and $d.Tags.ContainsKey($ExcludeTagKey)) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $d.Name `
            -Message ('Excluded - carries the {0} tag' -f $ExcludeTagKey)
        continue
    }

    $results.Add([PSCustomObject]@{
        Name          = $d.Name
        Id            = $d.Id
        ResourceGroup = $d.ResourceGroupName
        Location      = $d.Location
        SizeGB        = $d.DiskSizeGB
        Sku           = $d.Sku.Name
        DiskState     = "$($d.DiskState)"
        OsType        = "$($d.OsType)"
        CreatedAt     = $d.TimeCreated
        AgeDays       = [math]::Round(((Get-Date) - $d.TimeCreated).TotalDays, 1)
        EstMonthlyUsd = [math]::Round($d.DiskSizeGB * 0.05, 2)
        Tags          = if ($d.Tags) { (($d.Tags.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ') } else { '' }
    })
}
""",
    backup="""
# Mandatory pre-deletion snapshot, retained afterwards as the recovery path.
$snapName = $null
if (-not $SkipSnapshot) {
    $disk = Get-AzDisk -ResourceGroupName $item.ResourceGroup -DiskName $item.Name -ErrorAction Stop
    $snapName = ('predelete-{0}-{1}' -f $item.Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $cfg = New-AzSnapshotConfig -SourceUri $disk.Id -Location $item.Location -CreateOption Copy -SkuName Standard_LRS `
        -Tag @{ CreatedBy = $scriptName; Reason = 'pre-deletion recovery point'; Approval = "$ApprovalReference" }
    New-AzSnapshot -ResourceGroupName $item.ResourceGroup -SnapshotName $snapName -Snapshot $cfg -ErrorAction Stop | Out-Null
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
        'Pre-deletion snapshot {0} created and RETAINED as the recovery path' -f $snapName)
} else {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
        -Message 'PROCEEDING WITHOUT A SNAPSHOT - this deletion is unrecoverable'
}
""",
    act="""
Remove-AzDisk -ResourceGroupName $item.ResourceGroup -DiskName $item.Name -Force -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Disk DELETED: {0} ({1}GB, age {2}d). Recovery snapshot: {3}' -f
    $item.Name, $item.SizeGB, $item.AgeDays, $(if ($snapName) { $snapName } else { 'NONE' }))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Deleted'
    Detail = ('{0}GB; snapshot {1}' -f $item.SizeGB, $(if ($snapName) { $snapName } else { 'NONE' }))
    Succeeded = $true })
"""),
}

# Use cases 10, 12 and 17-32 live in their own module to keep this file readable.
try:
    from spec_azure2 import EXTRA as _EXTRA
    SPECS.update(_EXTRA)
except ImportError:
    pass
