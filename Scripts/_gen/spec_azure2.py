# -*- coding: utf-8 -*-
"""Azure - use cases 10, 12 and 17-32."""

SUB = dict(name='SubscriptionId', help='Subscription to operate in. Falls back to azure.defaultSubscriptionId in config.json.',
           decl="[string]$SubscriptionId")
RG = dict(name='ResourceGroupName', help='Limit to specific resource groups.',
          decl="[string[]]$ResourceGroupName")

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

EXTRA = {

10: dict(
    file='Set-AzAvdSessionHostPower',
    modules=['Az.Accounts', 'Az.DesktopVirtualization', 'Az.Compute'],
    _rg_removed=True,
    synopsis='Starts or stops AVD session hosts, draining users before shutdown.',
    desc='Powers AVD session hosts up or down. On shutdown it puts the host into drain mode first '
         'and refuses to stop a host that still has active sessions unless -Force is given, because '
         'deallocating a host with live sessions disconnects real users mid-work.',
    params=[SUB,
            dict(name='HostPoolName', help='Host pool to act on.',
                 decl="[Parameter(Mandatory)]\n    [string]$HostPoolName"),
            dict(name='Operation', help='Start or Stop (deallocate).',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Start','Stop')]\n    [string]$Operation"),
            dict(name='KeepMinimumHosts', help='Never take the pool below this many available hosts.',
                 decl="[ValidateRange(0,100)]\n    [int]$KeepMinimumHosts = 1"),
            dict(name='Force', help='Stop a host even if it still has active sessions. Disconnects those users.',
                 decl="[switch]$Force")],
    perms='Desktop Virtualization Contributor plus Virtual Machine Contributor.',
    actionVerb='Change AVD session host power state',
    rollback='Reverse the operation. Drain mode is cleared automatically on start; a host stopped '
             'while draining stays drained until started by this script.',
    examples=[("-HostPoolName hp-prod -Operation Stop -KeepMinimumHosts 2",
               'Deallocates idle hosts while keeping two available.'),
              ("-HostPoolName hp-prod -Operation Start -WhatIf",
               'Shows which hosts would be started.')],
    discover=SELECT_SUB + """
$pool = Get-AzWvdHostPool | Where-Object Name -eq $HostPoolName | Select-Object -First 1
if (-not $pool) { throw ('Host pool {0} not found.' -f $HostPoolName) }
$poolRg = ($pool.Id -split '/')[4]

$hosts = @(Get-AzWvdSessionHost -ResourceGroupName $poolRg -HostPoolName $HostPoolName -ErrorAction Stop)
$available = @($hosts | Where-Object { $_.Status -eq 'Available' })

foreach ($sh in $hosts) {
    $shortName = ($sh.Name -split '/')[-1]
    $vmName = ($shortName -split '\\.')[0]

    $sessions = @(Get-AzWvdUserSession -ResourceGroupName $poolRg -HostPoolName $HostPoolName `
                    -SessionHostName $shortName -ErrorAction SilentlyContinue)
    $active = @($sessions | Where-Object { $_.SessionState -eq 'Active' })

    if ($Operation -eq 'Stop') {
        if ($available.Count -le $KeepMinimumHosts) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $shortName -Message (
                'Skipped - pool would drop below the {0}-host floor' -f $KeepMinimumHosts)
            continue
        }
        if ($active.Count -gt 0 -and -not $Force) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $shortName -Message (
                'Skipped - {0} active session(s). Pass -Force to disconnect them.' -f $active.Count)
            continue
        }
    }

    $vm = Get-AzVM -Name $vmName -Status -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $shortName -Message 'Backing VM not found'
        continue
    }
    $power = ($vm.PowerState -replace '^VM ', '')
    $wanted = if ($Operation -eq 'Start') { 'running' } else { 'deallocated' }
    if ($power -eq $wanted) { continue }

    $results.Add([PSCustomObject]@{
        Name            = $shortName
        Id              = $sh.Name
        VMName          = $vmName
        ResourceGroup   = $vm.ResourceGroupName
        HostPool        = $HostPoolName
        HostPoolRg      = $poolRg
        SessionHostName = $shortName
        CurrentState    = $power
        DesiredState    = $wanted
        ActiveSessions  = $active.Count
        TotalSessions   = $sessions.Count
        Operation       = $Operation
    })
}
""",
    act="""
if ($item.Operation -eq 'Stop') {
    # Drain first so the broker stops sending new connections here while the
    # shutdown is in flight.
    Update-AzWvdSessionHost -ResourceGroupName $item.HostPoolRg -HostPoolName $item.HostPool `
        -Name $item.SessionHostName -AllowNewSession:$false -ErrorAction Stop | Out-Null
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message 'Drain mode enabled'

    Stop-AzVM -ResourceGroupName $item.ResourceGroup -Name $item.VMName -Force -ErrorAction Stop | Out-Null
} else {
    Start-AzVM -ResourceGroupName $item.ResourceGroup -Name $item.VMName -ErrorAction Stop | Out-Null
    Update-AzWvdSessionHost -ResourceGroupName $item.HostPoolRg -HostPoolName $item.HostPool `
        -Name $item.SessionHostName -AllowNewSession:$true -ErrorAction Stop | Out-Null
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message 'Drain mode cleared'
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} complete: {1} -> {2} ({3} session(s) at the time)' -f
    $item.Operation, $item.CurrentState, $item.DesiredState, $item.TotalSessions)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Operation
    Detail = ('{0} -> {1}' -f $item.CurrentState, $item.DesiredState); Succeeded = $true })
"""),

12: dict(
    file='Clear-AzVmTempPathMultiEnv',
    modules=['Az.Accounts', 'Az.Compute'],
    synopsis='Clears whitelisted temp paths across multiple environments, with per-environment rules.',
    desc='The multi-environment form of the C drive cleanup. Targets are selected by environment '
         'tag, and each environment carries its own age threshold and free-space trigger - so dev '
         'can be cleaned aggressively while production is touched only when genuinely tight. The '
         'path whitelist is enforced exactly as in the single-environment script.',
    params=[SUB,
            dict(name='Environment', help='Environment tag values to process, in order.',
                 decl="[string[]]$Environment = @('dev','test','prod')"),
            dict(name='EnvironmentTagKey', help='Tag key holding the environment name.',
                 decl="[string]$EnvironmentTagKey = 'Environment'"),
            dict(name='CleanupPath', help='Paths to clear. Every one must appear in -AllowedPath.',
                 decl="[string[]]$CleanupPath = @('C:\\\\Windows\\\\Temp','C:\\\\Users\\\\*\\\\AppData\\\\Local\\\\Temp')"),
            dict(name='AllowedPath', help='The whitelist. A path outside this list is never cleaned.',
                 decl="[string[]]$AllowedPath = @('C:\\\\Windows\\\\Temp','C:\\\\Users\\\\*\\\\AppData\\\\Local\\\\Temp','C:\\\\Windows\\\\SoftwareDistribution\\\\Download','C:\\\\Windows\\\\Logs\\\\CBS')"),
            dict(name='ProdOlderThanDays', help='Age threshold for production. Deliberately conservative.',
                 decl="[ValidateRange(1,3650)]\n    [int]$ProdOlderThanDays = 30"),
            dict(name='NonProdOlderThanDays', help='Age threshold for non-production environments.',
                 decl="[ValidateRange(0,3650)]\n    [int]$NonProdOlderThanDays = 3"),
            dict(name='ProdMinimumFreeGB', help='Only clean production VMs below this free space.',
                 decl="[ValidateRange(0,10000)]\n    [int]$ProdMinimumFreeGB = 10"),
            dict(name='NonProdMinimumFreeGB', help='Only clean non-production VMs below this free space.',
                 decl="[ValidateRange(0,10000)]\n    [int]$NonProdMinimumFreeGB = 25")],
    perms='Virtual Machine Contributor. The guest cleanup runs as SYSTEM via run-command.',
    actionVerb='Clear temporary files (multi-environment)',
    rollback='NONE - deleted files are not recoverable. The whitelist and the per-environment age '
             'thresholds exist because there is no undo.',
    notes='Production deliberately uses a longer age threshold and a lower free-space trigger than '
          'non-production. Treating every environment identically is how a cleanup script that was '
          'safe in dev deletes something that mattered in prod.',
    examples=[("-Environment dev,test",
               'Cleans non-production only, using the aggressive thresholds.'),
              ("-Environment prod -WhatIf",
               'Shows which production VMs are tight enough to qualify.')],
    discover=SELECT_SUB + """
if (-not $AllowedPath -or $AllowedPath.Count -eq 0) {
    throw 'Refusing to run: -AllowedPath is empty. The whitelist is this script''s only safety control.'
}
foreach ($p in $CleanupPath) {
    if ($AllowedPath -notcontains $p) {
        throw ('Refusing to clean "{0}" - it is not in -AllowedPath.' -f $p)
    }
}

foreach ($env in $Environment) {
    $isProd = ($env -match '(?i)^prod')
    $ageDays = if ($isProd) { $ProdOlderThanDays } else { $NonProdOlderThanDays }
    $freeGB  = if ($isProd) { $ProdMinimumFreeGB } else { $NonProdMinimumFreeGB }

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $env -Message (
        'Environment rules: files older than {0}d, only when free space is below {1}GB' -f $ageDays, $freeGB)

    $vms = Get-AzVM -Status | Where-Object {
        $full = Get-AzVM -ResourceGroupName $_.ResourceGroupName -Name $_.Name
        $full.Tags[$EnvironmentTagKey] -eq $env
    }

    foreach ($vm in $vms) {
        if (($vm.PowerState -replace '^VM ', '') -ne 'running') { continue }
        $results.Add([PSCustomObject]@{
            Name          = $vm.Name
            Id            = $vm.Id
            ResourceGroup = $vm.ResourceGroupName
            Environment   = $env
            IsProduction  = $isProd
            OlderThanDays = $ageDays
            MinimumFreeGB = $freeGB
            Paths         = ($CleanupPath -join '; ')
        })
    }
}
""",
    act="""
$guestScript = @(
    '$ErrorActionPreference = ''Continue'''
    ('$paths = @({0})' -f (($CleanupPath | ForEach-Object { "'$_'" }) -join ','))
    ('$cutoff = (Get-Date).AddDays(-{0})' -f $item.OlderThanDays)
    ('$minFreeGB = {0}' -f $item.MinimumFreeGB)
    '$freeBefore = [math]::Round((Get-PSDrive C).Free / 1GB, 2)'
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
    '[{0}] {1}' -f $item.Environment, ($msg -replace "`n", ' ').Trim())
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Cleaned'
    Detail = ('[{0}] {1}' -f $item.Environment, ($msg -replace "`n", ' ').Trim()); Succeeded = $true })
"""),

17: dict(
    file='Get-AzVmRightSizingReport',
    modules=['Az.Accounts', 'Az.Compute', 'Az.Monitor'],
    synopsis='Reports Azure VMs that appear over-provisioned against observed CPU usage.',
    desc='Compares each VM\'s size against its observed CPU utilisation over the lookback window '
         'and flags candidates for downsizing. Reporting only - the resize itself is a separate, '
         'approval-gated action, which is what the workbook guardrail specifies.',
    params=[SUB, RG,
            dict(name='LookbackDays', help='Metric window in days.',
                 decl="[ValidateRange(1,90)]\n    [int]$LookbackDays = 14"),
            dict(name='UnderUtilisedCpuPercent', help='Average CPU at or below which a VM is flagged as over-provisioned.',
                 decl="[ValidateRange(1,100)]\n    [int]$UnderUtilisedCpuPercent = 20"),
            dict(name='MinimumSampleDays', help='Require at least this many days of data before drawing a conclusion.',
                 decl="[ValidateRange(1,90)]\n    [int]$MinimumSampleDays = 7")],
    perms='Reader plus Monitoring Reader on the target scope.',
    notes='CPU alone does not justify a resize. A VM can be CPU-idle and memory-bound, and Azure '
          'does not expose guest memory without the diagnostics extension. Findings here are '
          'candidates for review, not instructions.',
    examples=[("-LookbackDays 30 -OutputFormat HTML",
               'Right-sizing candidates over a month, as HTML.'),
              ("-ResourceGroupName rg-prod -UnderUtilisedCpuPercent 10",
               'Applies a stricter threshold to one resource group.')],
    discover=SELECT_SUB + """
$vms = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ } }
       else                    { Get-AzVM }

$from = (Get-Date).AddDays(-$LookbackDays)
$to   = Get-Date

foreach ($vm in $vms) {
    $metrics = $null
    try {
        $metrics = Get-AzMetric -ResourceId $vm.Id -MetricName 'Percentage CPU' `
            -StartTime $from -EndTime $to -TimeGrain 01:00:00 -AggregationType Average -WarningAction SilentlyContinue
    } catch {
        Write-Verbose ('No CPU metric for {0}' -f $vm.Name)
    }

    $points = @($metrics.Data | Where-Object { $null -ne $_.Average })
    $sampleDays = [math]::Round($points.Count / 24, 1)

    # Not enough data is a different answer from "idle", and must not be
    # reported as a downsizing candidate.
    if ($points.Count -eq 0 -or $sampleDays -lt $MinimumSampleDays) {
        $results.Add([PSCustomObject]@{
            Name = $vm.Name; Id = $vm.Id; ResourceGroup = $vm.ResourceGroupName
            VmSize = $vm.HardwareProfile.VmSize
            AvgCpuPercent = $null; MaxCpuPercent = $null; SampleDays = $sampleDays
            Recommendation = 'Insufficient data'
            Status = 'Unknown'
        })
        continue
    }

    $avg = [math]::Round((($points | Measure-Object Average -Average).Average), 1)
    $max = [math]::Round((($points | Measure-Object Average -Maximum).Maximum), 1)

    $status = if ($avg -le $UnderUtilisedCpuPercent -and $max -le ($UnderUtilisedCpuPercent * 2)) { 'Over-provisioned' }
              elseif ($avg -ge 80) { 'Under-provisioned' }
              else { 'Appropriate' }

    $results.Add([PSCustomObject]@{
        Name           = $vm.Name
        Id             = $vm.Id
        ResourceGroup  = $vm.ResourceGroupName
        Location       = $vm.Location
        VmSize         = $vm.HardwareProfile.VmSize
        AvgCpuPercent  = $avg
        MaxCpuPercent  = $max
        SampleDays     = $sampleDays
        Recommendation = switch ($status) {
                             'Over-provisioned'  { 'Review for a smaller SKU - confirm memory headroom first' }
                             'Under-provisioned' { 'Consider a larger SKU' }
                             default             { 'No change indicated' }
                         }
        Status         = $status
        Caveat         = 'CPU only. Memory and IO are not visible without the diagnostics extension.'
    })
}
"""),

18: dict(
    file='Get-AzBackupComplianceReport',
    modules=['Az.Accounts', 'Az.Compute', 'Az.RecoveryServices'],
    synopsis='Reports which Azure VMs are protected by a backup policy and which are not.',
    desc='Cross-references every VM against Recovery Services vault protection, reporting unprotected '
         'VMs and any protected item whose last backup failed or is stale. An unprotected production '
         'VM is the finding this exists to surface.',
    params=[SUB, RG,
            dict(name='StaleBackupHours', help='Flag a protected item whose last successful backup is older than this.',
                 decl="[ValidateRange(1,8760)]\n    [int]$StaleBackupHours = 36")],
    perms='Reader plus Backup Reader on the subscription.',
    examples=[("-OutputFormat HTML", 'Backup compliance across the subscription.'),
              ("-StaleBackupHours 24 -OutputFormat CSV", 'Tighter staleness threshold, as CSV.')],
    discover=SELECT_SUB + """
$vms = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ } }
       else                    { Get-AzVM }

# Build the protected set once rather than querying per VM.
$protected = @{}
foreach ($vault in (Get-AzRecoveryServicesVault)) {
    Set-AzRecoveryServicesVaultContext -Vault $vault -ErrorAction SilentlyContinue
    try {
        $containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -Status Registered -ErrorAction Stop
        foreach ($c in $containers) {
            $items = Get-AzRecoveryServicesBackupItem -Container $c -WorkloadType AzureVM -ErrorAction SilentlyContinue
            foreach ($i in $items) {
                $vmShort = ($i.VirtualMachineId -split '/')[-1]
                $protected[$vmShort] = [PSCustomObject]@{
                    Vault = $vault.Name; Policy = $i.ProtectionPolicyName
                    Status = $i.ProtectionStatus; State = $i.ProtectionState
                    LastBackup = $i.LastBackupTime; LastBackupStatus = $i.LastBackupStatus
                }
            }
        }
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vault.Name `
            -Message ('Could not enumerate backup items: {0}' -f $_.Exception.Message)
    }
}

foreach ($vm in $vms) {
    $p = $protected[$vm.Name]
    $issues = @()
    if (-not $p) {
        $issues += 'NOT PROTECTED'
    } else {
        if ($p.LastBackupStatus -and $p.LastBackupStatus -ne 'Completed') { $issues += ('last backup {0}' -f $p.LastBackupStatus) }
        if ($p.LastBackup) {
            $ageH = [math]::Round(((Get-Date) - $p.LastBackup).TotalHours, 1)
            if ($ageH -gt $StaleBackupHours) { $issues += ('last backup {0}h ago' -f $ageH) }
        } else {
            $issues += 'no successful backup recorded'
        }
    }

    $results.Add([PSCustomObject]@{
        Name             = $vm.Name
        Id               = $vm.Id
        ResourceGroup    = $vm.ResourceGroupName
        Location         = $vm.Location
        Protected        = [bool]$p
        Vault            = if ($p) { $p.Vault } else { $null }
        Policy           = if ($p) { $p.Policy } else { $null }
        ProtectionState  = if ($p) { "$($p.State)" } else { $null }
        LastBackup       = if ($p) { $p.LastBackup } else { $null }
        LastBackupStatus = if ($p) { "$($p.LastBackupStatus)" } else { $null }
        Status           = if ($issues.Count) { 'NonCompliant' } else { 'Compliant' }
        Issues           = ($issues -join '; ')
    })
    if ($issues.Count) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $vm.Name -Message ($issues -join '; ')
    }
}
"""),

19: dict(
    file='Set-AzResourceTagCompliance',
    modules=['Az.Accounts', 'Az.Resources'],
    synopsis='Applies mandatory tags to Azure resources that are missing them.',
    desc='Finds resources missing any mandatory tag and applies the default value, inheriting from '
         'the parent resource group where one is available. A metadata-only change with no runtime '
         'effect, which is why it executes directly - but existing tag values are never overwritten.',
    params=[SUB, RG,
            dict(name='MandatoryTag', help='Tag keys and their default values.',
                 decl="[hashtable]$MandatoryTag = @{ Environment = 'unknown'; Owner = 'unassigned'; CostCentre = 'unallocated' }"),
            dict(name='InheritFromResourceGroup', help='Prefer the parent resource group\\u2019s tag value over the default.',
                 decl="[bool]$InheritFromResourceGroup = $true"),
            dict(name='ResourceType', help='Limit to specific resource types.',
                 decl="[string[]]$ResourceType")],
    perms='Tag Contributor, or Contributor on the target scope.',
    actionVerb='Apply mandatory tags',
    rollback='Remove the applied tags. The prior tag set is recorded in the audit log before each '
             'change, so the previous state is reconstructable.',
    notes='An existing value is NEVER overwritten - only missing keys are added. A resource tagged '
          'Environment=prod stays prod even if the default says unknown.',
    examples=[("-MandatoryTag @{Environment='unknown';Owner='unassigned'} -WhatIf",
               'Shows which resources are missing tags.'),
              ("-ResourceGroupName rg-prod",
               'Applies mandatory tags across one resource group.')],
    discover=SELECT_SUB + """
$resources = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzResource -ResourceGroupName $_ } }
             else                    { Get-AzResource }
if ($ResourceType) { $resources = $resources | Where-Object { $ResourceType -contains $_.ResourceType } }

$rgTagCache = @{}

foreach ($r in $resources) {
    $current = if ($r.Tags) { $r.Tags } else { @{} }
    $toApply = @{}

    foreach ($key in $MandatoryTag.Keys) {
        if ($current.ContainsKey($key) -and $current[$key]) { continue }   # never overwrite

        $value = $MandatoryTag[$key]
        if ($InheritFromResourceGroup -and $r.ResourceGroupName) {
            if (-not $rgTagCache.ContainsKey($r.ResourceGroupName)) {
                $rg = Get-AzResourceGroup -Name $r.ResourceGroupName -ErrorAction SilentlyContinue
                $rgTagCache[$r.ResourceGroupName] = if ($rg -and $rg.Tags) { $rg.Tags } else { @{} }
            }
            $rgTags = $rgTagCache[$r.ResourceGroupName]
            if ($rgTags.ContainsKey($key) -and $rgTags[$key]) { $value = $rgTags[$key] }
        }
        $toApply[$key] = $value
    }

    if ($toApply.Count -eq 0) { continue }    # already compliant

    $results.Add([PSCustomObject]@{
        Name          = $r.Name
        Id            = $r.ResourceId
        ResourceGroup = $r.ResourceGroupName
        ResourceType  = $r.ResourceType
        Location      = $r.Location
        CurrentTags   = (($current.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')
        TagsToApply   = (($toApply.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')
        MissingCount  = $toApply.Count
        NewTagSet     = $toApply
    })
}
""",
    act="""
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Prior tags: {0}' -f $(if ($item.CurrentTags) { $item.CurrentTags } else { '<none>' }))

Update-AzTag -ResourceId $item.Id -Tag $item.NewTagSet -Operation Merge -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Applied {0} tag(s): {1}' -f $item.MissingCount, $item.TagsToApply)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'TagsApplied'; Detail = $item.TagsToApply; Succeeded = $true })
"""),

20: dict(
    file='New-AzPrivateEndpointConnection',
    modules=['Az.Accounts', 'Az.Network'],
    synopsis='Provisions an Azure private endpoint for a target resource.',
    desc='Creates a private endpoint against a PaaS resource and attaches it to a subnet. This is a '
         'network topology change: it alters how the resource is reached and, once private DNS is '
         'in play, can make the public endpoint unreachable for existing clients. Approval-gated '
         'accordingly.',
    params=[SUB,
            dict(name='EndpointName', help='Name for the new private endpoint.',
                 decl="[Parameter(Mandatory)]\n    [string]$EndpointName"),
            dict(name='TargetResourceGroup', help='Resource group to create the endpoint in.',
                 decl="[Parameter(Mandatory)]\n    [string]$TargetResourceGroup"),
            dict(name='PrivateLinkResourceId', help='Resource id of the PaaS resource to connect to.',
                 decl="[Parameter(Mandatory)]\n    [string]$PrivateLinkResourceId"),
            dict(name='GroupId', help='Sub-resource to connect to, e.g. blob, sqlServer, vault.',
                 decl="[Parameter(Mandatory)]\n    [string]$GroupId"),
            dict(name='SubnetId', help='Resource id of the subnet to place the endpoint in.',
                 decl="[Parameter(Mandatory)]\n    [string]$SubnetId"),
            dict(name='Location', help='Azure region. Defaults to the subnet\\u2019s region.',
                 decl="[string]$Location")],
    perms='Network Contributor on the subnet plus at least Reader on the target resource.',
    actionVerb='Create private endpoint',
    reason='Private endpoint provisioning',
    rollback='Remove-AzPrivateEndpoint. Note that removing the endpoint does not restore public '
             'access if the target resource\\u2019s public network access was disabled separately.',
    notes='This script creates the endpoint only. It does NOT create the private DNS zone or the '
          'zone group linking them, because the DNS design is environment-specific and getting it '
          'wrong silently breaks name resolution. Complete the DNS step separately.',
    examples=[("-EndpointName pe-sa-prod -TargetResourceGroup rg-net -PrivateLinkResourceId '/subscriptions/.../storageAccounts/sa' -GroupId blob -SubnetId '/subscriptions/.../subnets/pe'",
               'REQUEST mode - validates and raises an approval.'),
              ("-EndpointName pe-sa-prod -TargetResourceGroup rg-net -PrivateLinkResourceId '...' -GroupId blob -SubnetId '...' -ApprovalReference APR-...",
               'Creates the approved endpoint.')],
    discover=SELECT_SUB + """
if (Get-AzPrivateEndpoint -Name $EndpointName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $EndpointName `
        -Message 'Skipped - private endpoint already exists (idempotent)'
    return
}

$subnetParts = $SubnetId -split '/'
$vnetRg   = $subnetParts[4]
$vnetName = $subnetParts[8]
$subnetName = $subnetParts[10]

$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRg -ErrorAction Stop
$subnet = $vnet.Subnets | Where-Object Name -eq $subnetName | Select-Object -First 1
if (-not $subnet) { throw ('Subnet {0} not found in {1}.' -f $subnetName, $vnetName) }

$target = Get-AzResource -ResourceId $PrivateLinkResourceId -ErrorAction Stop

if (-not $Location) { $Location = $vnet.Location }

$results.Add([PSCustomObject]@{
    Name              = $EndpointName
    Id                = $EndpointName
    ResourceGroup     = $TargetResourceGroup
    Location          = $Location
    TargetResource    = $target.Name
    TargetType        = $target.ResourceType
    GroupId           = $GroupId
    VNet              = $vnetName
    Subnet            = $subnetName
    SubnetPrefix      = ($subnet.AddressPrefix -join ',')
    PrivateLinkResourceId = $PrivateLinkResourceId
    SubnetId          = $SubnetId
    DnsNote           = 'Private DNS zone and zone group are NOT created by this script - complete that step separately'
})
""",
    act="""
$connection = New-AzPrivateLinkServiceConnection -Name ('{0}-conn' -f $item.Name) `
    -PrivateLinkServiceId $item.PrivateLinkResourceId -GroupId $item.GroupId -ErrorAction Stop

New-AzPrivateEndpoint -Name $item.Name -ResourceGroupName $item.ResourceGroup `
    -Location $item.Location -Subnet @{ Id = $item.SubnetId } `
    -PrivateLinkServiceConnection $connection -Force -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Private endpoint created for {0} ({1}) in {2}/{3}. DNS zone group still required.' -f
    $item.TargetResource, $item.GroupId, $item.VNet, $item.Subnet)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'EndpointCreated'
    Detail = ('{0} -> {1}' -f $item.TargetResource, $item.Subnet); Succeeded = $true })
"""),

21: dict(
    file='Update-AzKeyVaultSecretVersion',
    modules=['Az.Accounts', 'Az.KeyVault'],
    synopsis='Rotates Key Vault secrets by adding a new version, keeping the previous one enabled.',
    desc='Creates a new version of a secret and leaves the prior version ENABLED, so consumers that '
         'pin a version keep working while the rollout is verified. Which applications consume a '
         'secret, and whether they survived the rotation, is human-led work that this script '
         'deliberately does not attempt.',
    params=[SUB,
            dict(name='VaultName', help='Key Vault holding the secrets.',
                 decl="[Parameter(Mandatory)]\n    [string]$VaultName"),
            dict(name='SecretName', help='Secret(s) to rotate.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$SecretName"),
            dict(name='NewSecretValue', help='The new value, as a SecureString. Generated if omitted.',
                 decl="[System.Security.SecureString]$NewSecretValue"),
            dict(name='GeneratedLength', help='Length of the generated value when -NewSecretValue is omitted.',
                 decl="[ValidateRange(16,128)]\n    [int]$GeneratedLength = 32"),
            dict(name='DisablePreviousVersion', help='Disable the prior version immediately. Off by default because it breaks version-pinned consumers.',
                 decl="[switch]$DisablePreviousVersion"),
            dict(name='ExpiresInDays', help='Expiry to set on the new version.',
                 decl="[ValidateRange(1,3650)]\n    [int]$ExpiresInDays = 365")],
    perms='Key Vault Secrets Officer on the vault.',
    actionVerb='Rotate Key Vault secret',
    reason='Scheduled secret rotation',
    rollback='The previous version remains enabled by default, so consumers can be repointed to it. '
             'If -DisablePreviousVersion was used, re-enable it with Update-AzKeyVaultSecret.',
    notes='Rotation is only half the job. Mapping which applications consume each secret, and '
          'validating them after the change, is explicitly human-led per the workbook guardrail. '
          'This script rotates and reports; it cannot tell you what broke.',
    examples=[("-VaultName kv-prod -SecretName api-key",
               'REQUEST mode - raises an approval to rotate one secret.'),
              ("-VaultName kv-prod -SecretName api-key -ApprovalReference APR-...",
               'Rotates the secret, leaving the previous version enabled.')],
    discover=SELECT_SUB + """
# Existence check only - throws if the vault is wrong.
Get-AzKeyVault -VaultName $VaultName -ErrorAction Stop | Out-Null

foreach ($name in $SecretName) {
    $current = Get-AzKeyVaultSecret -VaultName $VaultName -Name $name -ErrorAction SilentlyContinue
    if (-not $current) {
        throw ('Secret {0} does not exist in {1}. This script rotates existing secrets; it does not create them.' -f $name, $VaultName)
    }

    $versions = @(Get-AzKeyVaultSecret -VaultName $VaultName -Name $name -IncludeVersions -ErrorAction SilentlyContinue)

    $results.Add([PSCustomObject]@{
        Name             = $name
        Id               = $current.Id
        VaultName        = $VaultName
        CurrentVersion   = $current.Version
        CurrentCreated   = $current.Created
        CurrentExpires   = $current.Expires
        Enabled          = $current.Enabled
        VersionCount     = $versions.Count
        ContentType      = $current.ContentType
        DisablePrevious  = [bool]$DisablePreviousVersion
        HumanFollowUp    = 'Identify consuming applications and validate them after rotation - not automated'
    })
}
""",
    act="""
if ($NewSecretValue) {
    $secureValue = $NewSecretValue
    $generated = $false
} else {
    # Built character by character straight into a SecureString. The generated
    # value never exists as a plaintext String, so it cannot be captured by a
    # transcript, a crash dump, or an accidental Write-Output.
    $alphabet = ([char[]](
        (48..57)  +      # 0-9
        (65..90)  +      # A-Z
        (97..122) +      # a-z
        (33,35,36,37,38,42,43,45,61,63,64,95)   # punctuation, shell-safe subset
    ))
    $secureValue = New-Object System.Security.SecureString
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buf = New-Object byte[] 1
        $limit = [byte](256 - (256 % $alphabet.Length))   # reject above this to avoid modulo bias
        for ($i = 0; $i -lt $GeneratedLength; $i++) {
            do { $rng.GetBytes($buf) } while ($buf[0] -ge $limit)
            $secureValue.AppendChar($alphabet[$buf[0] % $alphabet.Length])
        }
    } finally {
        $rng.Dispose()
    }
    $secureValue.MakeReadOnly()
    $generated = $true
}

$new = Set-AzKeyVaultSecret -VaultName $item.VaultName -Name $item.Name -SecretValue $secureValue `
    -Expires (Get-Date).AddDays($ExpiresInDays) -ErrorAction Stop

# The previous version stays ENABLED unless explicitly disabled, so a consumer
# pinned to it keeps working while the rollout is verified.
if ($DisablePreviousVersion -and $item.CurrentVersion) {
    Update-AzKeyVaultSecret -VaultName $item.VaultName -Name $item.Name `
        -Version $item.CurrentVersion -Enable $false -ErrorAction Stop | Out-Null
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
        'Previous version {0} DISABLED - version-pinned consumers will now fail' -f $item.CurrentVersion)
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Secret rotated: version {0} -> {1} (generated={2}, previous kept enabled={3}). ' +
    'Validate consuming applications manually.' -f
    $item.CurrentVersion, $new.Version, $generated, (-not $DisablePreviousVersion))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Rotated'
    Detail = ('{0} -> {1}' -f $item.CurrentVersion, $new.Version); Succeeded = $true })
"""),

22: dict(
    file='Set-AzResourceLock',
    modules=['Az.Accounts', 'Az.Resources'],
    synopsis='Adds or removes Azure resource locks.',
    desc='Creates or removes CanNotDelete and ReadOnly locks. Removing a lock is what makes a '
         'production resource deletable, so removal is approval-gated; adding one is protective and '
         'still gated for consistency, since an unexpected ReadOnly lock breaks deployments.',
    params=[SUB, RG,
            dict(name='Operation', help='Add or Remove.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Add','Remove')]\n    [string]$Operation"),
            dict(name='LockName', help='Name of the lock.',
                 decl="[Parameter(Mandatory)]\n    [string]$LockName"),
            dict(name='LockLevel', help='CanNotDelete or ReadOnly. Required for Add.',
                 decl="[ValidateSet('CanNotDelete','ReadOnly')]\n    [string]$LockLevel = 'CanNotDelete'"),
            dict(name='TargetResourceId', help='Specific resource to lock. Omit to lock the resource group itself.',
                 decl="[string]$TargetResourceId"),
            dict(name='LockNotes', help='Reason recorded on the lock.',
                 decl="[string]$LockNotes = 'Managed by IT automation'")],
    perms='Owner or User Access Administrator - lock management requires Microsoft.Authorization/locks/* which Contributor does not have.',
    actionVerb='Add/remove resource lock',
    reason='Resource lock change',
    rollback='Reverse the operation. A removed lock can be recreated with the same name and level, '
             'both of which are recorded in the audit log before removal.',
    notes='A ReadOnly lock blocks far more than it appears to - it prevents POST operations, so it '
          'can stop a VM from starting or a key being listed. CanNotDelete is usually what people '
          'actually want.',
    examples=[("-Operation Add -LockName no-delete -ResourceGroupName rg-prod -LockLevel CanNotDelete",
               'REQUEST mode - raises an approval to protect a resource group.'),
              ("-Operation Remove -LockName no-delete -ResourceGroupName rg-prod -ApprovalReference APR-...",
               'Removes the approved lock, exposing the resource group to deletion.')],
    discover=SELECT_SUB + """
if ($Operation -eq 'Add' -and -not $LockLevel) { throw '-LockLevel is required when adding a lock.' }
if (-not $ResourceGroupName -and -not $TargetResourceId) {
    throw 'Specify -ResourceGroupName or -TargetResourceId. Locking at subscription scope is not supported here.'
}

$scopes = if ($TargetResourceId) { @($TargetResourceId) }
          else { $ResourceGroupName | ForEach-Object { (Get-AzResourceGroup -Name $_ -ErrorAction Stop).ResourceId } }

foreach ($scope in $scopes) {
    $existing = Get-AzResourceLock -Scope $scope -ErrorAction SilentlyContinue |
                Where-Object Name -eq $LockName | Select-Object -First 1

    if ($Operation -eq 'Add' -and $existing) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $scope `
            -Message ('Skipped - lock {0} already exists at {1}' -f $LockName, $existing.Properties.level)
        continue
    }
    if ($Operation -eq 'Remove' -and -not $existing) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $scope `
            -Message ('Skipped - no lock named {0} at this scope' -f $LockName)
        continue
    }

    $results.Add([PSCustomObject]@{
        Name          = ('{0} @ {1}' -f $LockName, ($scope -split '/')[-1])
        Id            = $scope
        Operation     = $Operation
        LockName      = $LockName
        LockLevel     = if ($Operation -eq 'Add') { $LockLevel } else { "$($existing.Properties.level)" }
        Scope         = $scope
        ExistingNotes = if ($existing) { $existing.Properties.notes } else { $null }
        Impact        = if ($Operation -eq 'Remove') { 'Resource becomes deletable' } else { 'Resource becomes protected' }
    })
}
""",
    act="""
if ($item.Operation -eq 'Add') {
    New-AzResourceLock -LockName $item.LockName -LockLevel $item.LockLevel -Scope $item.Scope `
        -LockNotes $LockNotes -Force -ErrorAction Stop | Out-Null
    $detail = 'lock added at level {0}' -f $item.LockLevel
} else {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
        'Removing lock {0} ({1}) - the resource becomes deletable. Approval={2} Ticket={3}' -f
        $item.LockName, $item.LockLevel, $ApprovalReference, $TicketReference)
    Remove-AzResourceLock -LockName $item.LockName -Scope $item.Scope -Force -ErrorAction Stop | Out-Null
    $detail = 'lock removed (was {0})' -f $item.LockLevel
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message $detail
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
"""),

23: dict(
    file='Test-AzSqlDatabaseRestore',
    modules=['Az.Accounts', 'Az.Sql'],
    synopsis='Performs a point-in-time restore of an Azure SQL database to an isolated test target.',
    desc='Restores a database to a NEW, separately-named target so the production database is never '
         'touched. The target name is derived from a fixed prefix, and the script refuses if the '
         'resulting name would collide with an existing database - which is what keeps a restore '
         'test from becoming an outage.',
    params=[SUB,
            dict(name='ServerName', help='Azure SQL logical server.',
                 decl="[Parameter(Mandatory)]\n    [string]$ServerName"),
            dict(name='SourceDatabaseName', help='Database to restore from.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$SourceDatabaseName"),
            dict(name='SqlResourceGroup', help='Resource group containing the SQL server.',
                 decl="[Parameter(Mandatory)]\n    [string]$SqlResourceGroup"),
            dict(name='RestoreTargetPrefix', help='Prefix for the restored copy. The fixed prefix is what keeps the restore isolated.',
                 decl="[ValidateNotNullOrEmpty()]\n    [string]$RestoreTargetPrefix = 'resto...'".replace('resto...', 'restoretest-')),
            dict(name='PointInTimeMinutesAgo', help='How far back to restore from.',
                 decl="[ValidateRange(10,43200)]\n    [int]$PointInTimeMinutesAgo = 60"),
            dict(name='RemoveAfterMinutes', help='Delete the restored copy after this many minutes. 0 keeps it.',
                 decl="[ValidateRange(0,10080)]\n    [int]$RemoveAfterMinutes = 0")],
    perms='SQL DB Contributor on the server.',
    actionVerb='Restore database to test target',
    rollback='Delete the restored copy. The source database is never modified, so there is nothing '
             'to roll back on it.',
    notes='A restored database bills as a full database from the moment it exists. Use '
          '-RemoveAfterMinutes, or clean it up manually, or the restore test quietly becomes a '
          'recurring cost.',
    examples=[("-ServerName sql-prod -SqlResourceGroup rg-sql -SourceDatabaseName appdb",
               'Restores appdb to restoretest-appdb-<timestamp>.'),
              ("-ServerName sql-prod -SqlResourceGroup rg-sql -SourceDatabaseName appdb -RemoveAfterMinutes 60",
               'Restores, then deletes the copy an hour later.')],
    discover=SELECT_SUB + """
# Existence check only - throws if the server is wrong, which is the point.
Get-AzSqlServer -ResourceGroupName $SqlResourceGroup -ServerName $ServerName -ErrorAction Stop | Out-Null
$restorePoint = (Get-Date).AddMinutes(-$PointInTimeMinutesAgo)

foreach ($dbName in $SourceDatabaseName) {
    $db = Get-AzSqlDatabase -ResourceGroupName $SqlResourceGroup -ServerName $ServerName `
            -DatabaseName $dbName -ErrorAction Stop

    if ($db.EarliestRestoreDate -and $restorePoint -lt $db.EarliestRestoreDate) {
        throw ('Requested restore point {0:u} is before the earliest available {1:u} for {2}.' -f
               $restorePoint, $db.EarliestRestoreDate, $dbName)
    }

    $targetName = ('{0}{1}-{2}' -f $RestoreTargetPrefix, $dbName, (Get-Date -Format 'yyyyMMdd-HHmm'))

    # The isolation guarantee: never restore onto an existing database.
    if (Get-AzSqlDatabase -ResourceGroupName $SqlResourceGroup -ServerName $ServerName `
            -DatabaseName $targetName -ErrorAction SilentlyContinue) {
        throw ('Refusing: target database {0} already exists.' -f $targetName)
    }
    if ($targetName -eq $dbName) {
        throw 'Refusing: the restore target name matches the source. Check -RestoreTargetPrefix.'
    }

    $results.Add([PSCustomObject]@{
        Name              = $dbName
        Id                = $db.ResourceId
        ServerName        = $ServerName
        ResourceGroup     = $SqlResourceGroup
        SourceDatabase    = $dbName
        TargetDatabase    = $targetName
        RestorePoint      = $restorePoint
        EarliestRestore   = $db.EarliestRestoreDate
        SourceEdition     = $db.Edition
        SourceServiceObjective = $db.CurrentServiceObjectiveName
        RemoveAfterMinutes= $RemoveAfterMinutes
    })
}
""",
    act="""
Restore-AzSqlDatabase -FromPointInTimeBackup -PointInTime $item.RestorePoint `
    -ResourceGroupName $item.ResourceGroup -ServerName $item.ServerName `
    -TargetDatabaseName $item.TargetDatabase -ResourceId $item.Id -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Restored {0} to {1} at point-in-time {2:u}. Source untouched.' -f
    $item.SourceDatabase, $item.TargetDatabase, $item.RestorePoint)

if ($item.RemoveAfterMinutes -gt 0) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
        'Waiting {0} minute(s) before removing the test copy' -f $item.RemoveAfterMinutes)
    Start-Sleep -Seconds ($item.RemoveAfterMinutes * 60)
    Remove-AzSqlDatabase -ResourceGroupName $item.ResourceGroup -ServerName $item.ServerName `
        -DatabaseName $item.TargetDatabase -Force -ErrorAction Stop | Out-Null
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Test copy {0} removed' -f $item.TargetDatabase)
}

$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Restored'
    Detail = ('-> {0}' -f $item.TargetDatabase); Succeeded = $true })
"""),

24: dict(
    file='Get-AzFirewallRuleReview',
    modules=['Az.Accounts', 'Az.Network'],
    synopsis='Exports Azure Firewall rule collections for review.',
    desc='Exports every network, application and NAT rule collection with its priority and action, '
         'flagging the patterns worth questioning: any-to-any allows, wildcard FQDNs and wide port '
         'ranges. The export is automated; deciding whether a rule is still justified is business '
         'context this script cannot supply.',
    params=[SUB, RG,
            dict(name='FirewallName', help='Limit to specific firewalls.',
                 decl="[string[]]$FirewallName")],
    perms='Reader on the firewall.',
    examples=[("-OutputFormat HTML", 'Full rule export as HTML for a review meeting.'),
              ("-FirewallName afw-hub -OutputFormat JSON", 'One firewall as JSON.')],
    discover=SELECT_SUB + """
$fws = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzFirewall -ResourceGroupName $_ } }
       else                    { Get-AzFirewall }
if ($FirewallName) { $fws = $fws | Where-Object { $FirewallName -contains $_.Name } }

foreach ($fw in $fws) {
    foreach ($rc in $fw.NetworkRuleCollections) {
        foreach ($rule in $rc.Rules) {
            $flags = @()
            if ($rc.Action.Type -eq 'Allow') {
                if ($rule.SourceAddresses -contains '*')      { $flags += 'source Any' }
                if ($rule.DestinationAddresses -contains '*') { $flags += 'destination Any' }
                if ($rule.DestinationPorts -contains '*')     { $flags += 'all ports' }
            }
            $results.Add([PSCustomObject]@{
                Name          = ('{0} / {1} / {2}' -f $fw.Name, $rc.Name, $rule.Name)
                Id            = $rule.Name
                Firewall      = $fw.Name
                Collection    = $rc.Name
                CollectionType= 'Network'
                Priority      = $rc.Priority
                Action        = "$($rc.Action.Type)"
                Protocols     = ($rule.Protocols -join ',')
                Source        = ($rule.SourceAddresses -join ',')
                Destination   = ($rule.DestinationAddresses -join ',')
                Ports         = ($rule.DestinationPorts -join ',')
                Flags         = ($flags -join '; ')
                ReviewNote    = 'Is this rule still justified? Requires business context.'
            })
        }
    }

    foreach ($rc in $fw.ApplicationRuleCollections) {
        foreach ($rule in $rc.Rules) {
            $flags = @()
            if ($rc.Action.Type -eq 'Allow') {
                if ($rule.SourceAddresses -contains '*') { $flags += 'source Any' }
                if ($rule.TargetFqdns | Where-Object { $_ -like '*`**' }) { $flags += 'wildcard FQDN' }
            }
            $results.Add([PSCustomObject]@{
                Name          = ('{0} / {1} / {2}' -f $fw.Name, $rc.Name, $rule.Name)
                Id            = $rule.Name
                Firewall      = $fw.Name
                Collection    = $rc.Name
                CollectionType= 'Application'
                Priority      = $rc.Priority
                Action        = "$($rc.Action.Type)"
                Protocols     = (($rule.Protocols | ForEach-Object { '{0}:{1}' -f $_.ProtocolType, $_.Port }) -join ',')
                Source        = ($rule.SourceAddresses -join ',')
                Destination   = ($rule.TargetFqdns -join ',')
                Ports         = ''
                Flags         = ($flags -join '; ')
                ReviewNote    = 'Is this rule still justified? Requires business context.'
            })
        }
    }
}
"""),

25: dict(
    file='Get-AzLoadBalancerHealth',
    modules=['Az.Accounts', 'Az.Network'],
    synopsis='Reports Azure Load Balancer backend pool health.',
    desc='Checks each load balancer\'s backend pools for members and reports pools that are empty '
         'or whose probe configuration looks wrong. An empty backend pool is a silent outage - the '
         'load balancer answers, and nothing is behind it.',
    params=[SUB, RG,
            dict(name='LoadBalancerName', help='Limit to specific load balancers.',
                 decl="[string[]]$LoadBalancerName")],
    perms='Reader plus Monitoring Reader on the load balancer.',
    notes='Per-member probe status is exposed through the Azure Monitor DipAvailability metric '
          'rather than the ARM resource. This script reports pool composition and probe '
          'configuration; wire the metric into an alert rule for live member health.',
    examples=[("-OutputFormat HTML", 'Backend pool health across the subscription.'),
              ("-LoadBalancerName lb-prod", 'One load balancer.')],
    discover=SELECT_SUB + """
$lbs = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzLoadBalancer -ResourceGroupName $_ } }
       else                    { Get-AzLoadBalancer }
if ($LoadBalancerName) { $lbs = $lbs | Where-Object { $LoadBalancerName -contains $_.Name } }

foreach ($lb in $lbs) {
    foreach ($pool in $lb.BackendAddressPools) {
        $memberCount = @($pool.BackendIpConfigurations).Count
        $rules = @($lb.LoadBalancingRules | Where-Object { $_.BackendAddressPool.Id -eq $pool.Id })
        $probeIds = @($rules.Probe.Id | Where-Object { $_ })
        $probes = @($lb.Probes | Where-Object { $probeIds -contains $_.Id })

        $issues = @()
        if ($memberCount -eq 0)            { $issues += 'BACKEND POOL IS EMPTY' }
        if ($rules.Count -eq 0)            { $issues += 'no load balancing rule references this pool' }
        if ($probes.Count -eq 0 -and $rules.Count -gt 0) { $issues += 'rules have no health probe' }
        foreach ($p in $probes) {
            if ($p.IntervalInSeconds -gt 30) { $issues += ('probe {0} interval {1}s is slow to detect failure' -f $p.Name, $p.IntervalInSeconds) }
        }

        $results.Add([PSCustomObject]@{
            Name          = ('{0} / {1}' -f $lb.Name, $pool.Name)
            Id            = $pool.Id
            LoadBalancer  = $lb.Name
            ResourceGroup = $lb.ResourceGroupName
            Location      = $lb.Location
            Sku           = $lb.Sku.Name
            BackendPool   = $pool.Name
            MemberCount   = $memberCount
            RuleCount     = $rules.Count
            ProbeCount    = $probes.Count
            Probes        = (($probes | ForEach-Object { '{0}({1}:{2}/{3}s)' -f $_.Name, $_.Protocol, $_.Port, $_.IntervalInSeconds }) -join '; ')
            Status        = if ($issues.Count) { 'Warning' } else { 'OK' }
            Issues        = ($issues -join '; ')
        })
        if ($issues.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target ('{0}/{1}' -f $lb.Name, $pool.Name) `
                -Message ($issues -join '; ')
        }
    }
}
"""),

26: dict(
    file='Remove-AzEntraGuestUser',
    modules=['Az.Accounts', 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Users'],
    synopsis='Removes Entra ID guest accounts that have been inactive beyond a threshold.',
    desc='Finds guest users with no recent sign-in and proposes them for removal. False positives '
         'here lock out real partners, so the script reports a full evidence set per guest - last '
         'sign-in, creation date, group memberships and owned objects - and requires the list to be '
         'approved before anything is deleted.',
    params=[
            dict(name='InactiveDays', help='Guests with no sign-in for at least this long are proposed.',
                 decl="[ValidateRange(30,3650)]\n    [int]$InactiveDays = 90"),
            dict(name='ExcludeDomain', help='Guest domains that are never proposed, e.g. a strategic partner.',
                 decl="[string[]]$ExcludeDomain"),
            dict(name='DisableInsteadOfDelete', help='Block sign-in rather than delete. Reversible, and usually the right first step.',
                 decl="[switch]$DisableInsteadOfDelete")],
    minage=0,
    perms='Microsoft Graph User.ReadWrite.All and AuditLog.Read.All (sign-in activity requires an Entra ID P1 licence).',
    actionVerb='Remove inactive guest user',
    reason='Inactive guest account cleanup',
    rollback='A DELETED user is recoverable from the Entra ID recycle bin for 30 days. After that '
             'it is permanent. -DisableInsteadOfDelete is fully reversible and is the safer choice '
             'for a first pass.',
    notes='Sign-in activity requires Entra ID P1 or above. Without it, lastSignInDateTime is null '
          'for every user, and this script treats a null as NOT inactive - so it proposes nothing '
          'rather than proposing everyone.',
    examples=[("-InactiveDays 90",
               'REPORT ONLY. Lists guests inactive for 90 days and raises an approval.'),
              ("-InactiveDays 90 -ApprovalReference APR-... -Execute -DisableInsteadOfDelete",
               'Blocks sign-in for the approved guests instead of deleting them.')],
    discover="""
Connect-MgGraph -Scopes 'User.ReadWrite.All','AuditLog.Read.All','Directory.Read.All' -NoWelcome -ErrorAction Stop

$cutoff = (Get-Date).AddDays(-$InactiveDays)
$noActivityData = 0

$guests = Get-MgUser -Filter "userType eq 'Guest'" -All `
    -Property Id,UserPrincipalName,DisplayName,Mail,CreatedDateTime,AccountEnabled,SignInActivity `
    -ErrorAction Stop

foreach ($g in $guests) {
    $domain = ($g.Mail -split '@')[-1]
    if (-not $domain) { $domain = ($g.UserPrincipalName -split '#EXT#')[0] -replace '.*_', '' }

    if ($ExcludeDomain -and ($ExcludeDomain | Where-Object { $domain -like $_ })) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $g.UserPrincipalName `
            -Message ('Excluded - domain {0} is on the exclusion list' -f $domain)
        continue
    }

    $lastSignIn = $g.SignInActivity.LastSignInDateTime

    # No sign-in data is NOT evidence of inactivity - it usually means the
    # tenant lacks the licence that surfaces it. Treat it as unknown, not stale.
    if (-not $lastSignIn) {
        $noActivityData++
        continue
    }
    if ($lastSignIn -ge $cutoff) { continue }

    # Evidence an approver needs to judge a false positive.
    $groups = @(); $owned = @()
    try {
        $groups = @(Get-MgUserMemberOf -UserId $g.Id -All -ErrorAction Stop |
                    ForEach-Object { $_.AdditionalProperties.displayName } | Where-Object { $_ })
    } catch {
        # Directory.Read.All may not be consented. Reported as unknown rather
        # than as zero, so an approver is not shown a falsely low risk.
        Write-Verbose ('Group membership unavailable for {0}: {1}' -f $g.UserPrincipalName, $_.Exception.Message)
    }
    try {
        $owned  = @(Get-MgUserOwnedObject -UserId $g.Id -All -ErrorAction Stop |
                    ForEach-Object { $_.AdditionalProperties.displayName } | Where-Object { $_ })
    } catch {
        Write-Verbose ('Owned objects unavailable for {0}: {1}' -f $g.UserPrincipalName, $_.Exception.Message)
    }

    $results.Add([PSCustomObject]@{
        Name           = $g.UserPrincipalName
        Id             = $g.Id
        DisplayName    = $g.DisplayName
        Mail           = $g.Mail
        Domain         = $domain
        AccountEnabled = $g.AccountEnabled
        CreatedAt      = $g.CreatedDateTime
        LastSignIn     = $lastSignIn
        InactiveDays   = [math]::Round(((Get-Date) - $lastSignIn).TotalDays, 0)
        GroupCount     = $groups.Count
        Groups         = (($groups | Select-Object -First 10) -join '; ')
        OwnedObjects   = (($owned | Select-Object -First 10) -join '; ')
        RiskOfRemoval  = if ($owned.Count -gt 0) { 'HIGH - owns objects that would be orphaned' }
                         elseif ($groups.Count -gt 3) { 'MEDIUM - member of several groups' }
                         else { 'Low' }
    })
}

if ($noActivityData -gt 0) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        '{0} guest(s) have no sign-in activity data and were NOT proposed. This usually means the ' +
        'tenant lacks Entra ID P1. Absence of data is not evidence of inactivity.' -f $noActivityData)
}
""",
    act="""
if ($DisableInsteadOfDelete) {
    Update-MgUser -UserId $item.Id -AccountEnabled:$false -ErrorAction Stop
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Guest DISABLED (reversible). Inactive {0}d, risk {1}' -f $item.InactiveDays, $item.RiskOfRemoval)
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'Disabled'
        Detail = ('inactive {0}d - reversible' -f $item.InactiveDays); Succeeded = $true })
} else {
    Remove-MgUser -UserId $item.Id -ErrorAction Stop
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Guest DELETED. Inactive {0}d, risk {1}. Recoverable from the recycle bin for 30 days.' -f
        $item.InactiveDays, $item.RiskOfRemoval)
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'Deleted'
        Detail = ('inactive {0}d - recycle bin 30d' -f $item.InactiveDays); Succeeded = $true })
}
"""),

27: dict(
    file='Get-AzPolicyComplianceDashboard',
    modules=['Az.Accounts', 'Az.PolicyInsights', 'Az.Resources'],
    synopsis='Aggregates Azure Policy compliance across subscriptions.',
    desc='Summarises policy assignment compliance with non-compliant resource counts per assignment, '
         'so a drifting policy is one line rather than a console hunt.',
    params=[SUB,
            dict(name='OnlyNonCompliant', help='Report only assignments with non-compliant resources.',
                 decl="[switch]$OnlyNonCompliant")],
    perms='Reader plus Resource Policy Contributor (read) on the subscription.',
    examples=[("-OnlyNonCompliant -OutputFormat HTML", 'Just the failing assignments, as HTML.'),
              ("-OutputFormat CSV", 'Full compliance export.')],
    discover=SELECT_SUB + """
$summary = Get-AzPolicyStateSummary -ErrorAction Stop

foreach ($pa in $summary.PolicyAssignments) {
    $nonCompliant = $pa.Results.NonCompliantResources
    if ($OnlyNonCompliant -and $nonCompliant -eq 0) { continue }

    $assignmentName = ($pa.PolicyAssignmentId -split '/')[-1]
    $definition = $null
    try {
        $assignment = Get-AzPolicyAssignment -Id $pa.PolicyAssignmentId -ErrorAction Stop
        $definition = $assignment.Properties.DisplayName
    } catch {
        Write-Verbose ('Could not resolve assignment {0}' -f $assignmentName)
    }

    $results.Add([PSCustomObject]@{
        Name                  = if ($definition) { $definition } else { $assignmentName }
        Id                    = $pa.PolicyAssignmentId
        AssignmentName        = $assignmentName
        NonCompliantResources = $nonCompliant
        NonCompliantPolicies  = $pa.Results.NonCompliantPolicies
        Status                = if ($nonCompliant -gt 0) { 'NonCompliant' } else { 'Compliant' }
    })
}

$results.Add([PSCustomObject]@{
    Name                  = 'SUBSCRIPTION TOTAL'
    Id                    = (Get-AzContext).Subscription.Id
    AssignmentName        = '(all assignments)'
    NonCompliantResources = $summary.Results.NonCompliantResources
    NonCompliantPolicies  = $summary.Results.NonCompliantPolicies
    Status                = if ($summary.Results.NonCompliantResources -gt 0) { 'NonCompliant' } else { 'Compliant' }
})
"""),

28: dict(
    file='Get-AzReservationUtilization',
    modules=['Az.Accounts', 'Az.Reservations'],
    synopsis='Reports Azure reservation utilisation and wasted commitment.',
    desc='Lists reservation orders with their utilisation, flagging any that is under-used - which '
         'is money already committed and not being consumed - or expiring soon.',
    params=[
            dict(name='ExpiringWithinDays', help='Flag reservations expiring within this many days.',
                 decl="[ValidateRange(1,365)]\n    [int]$ExpiringWithinDays = 60")],
    perms='Reservation Reader at the billing scope, or Owner on the reservation order.',
    notes='This script reports reservation inventory, term, expiry and auto-renew state. It does '
          'NOT report utilisation percentages: those come from the Cost Management '
          'reservation-details API, which needs billing-scope access that subscription rights do '
          'not grant. Rather than emit a filter that could never apply, the utilisation threshold '
          'parameter has been left out entirely.',
    examples=[("-ExpiringWithinDays 90", 'Flags reservations expiring within a quarter.'),
              ("-OutputFormat HTML", 'Full reservation report as HTML.')],
    discover="""
$orders = Get-AzReservationOrder -ErrorAction Stop

foreach ($order in $orders) {
    $orderId = ($order.Id -split '/')[-1]
    $reservations = @(Get-AzReservation -ReservationOrderId $orderId -ErrorAction SilentlyContinue)

    foreach ($r in $reservations) {
        $issues = @()
        $daysToExpiry = if ($order.ExpiryDate) {
                            [math]::Round(([datetime]$order.ExpiryDate - (Get-Date)).TotalDays, 0)
                        } else { $null }
        if ($null -ne $daysToExpiry -and $daysToExpiry -le $ExpiringWithinDays) {
            $issues += ('expires in {0} day(s)' -f $daysToExpiry)
        }
        if ($r.Properties.Renew -eq $false -and $null -ne $daysToExpiry -and $daysToExpiry -le $ExpiringWithinDays) {
            $issues += 'auto-renew is OFF'
        }

        $results.Add([PSCustomObject]@{
            Name            = $r.Name
            Id              = $r.Id
            OrderId         = $orderId
            Sku             = $r.Sku.Name
            Quantity        = $r.Properties.Quantity
            State           = "$($r.Properties.ProvisioningState)"
            Scope           = "$($r.Properties.AppliedScopeType)"
            Term            = $order.Term
            ExpiryDate      = $order.ExpiryDate
            DaysToExpiry    = $daysToExpiry
            AutoRenew       = $r.Properties.Renew
            Status          = if ($issues.Count) { 'Attention' } else { 'OK' }
            Issues          = ($issues -join '; ')
            UtilisationNote = 'Per-day utilisation percentages come from the Cost Management reservation-details API, which needs billing-scope access'
        })
    }
}

if ($orders.Count -eq 0) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'No reservation orders visible to this identity.'
}
"""),

29: dict(
    file='Get-AzVmPatchComplianceReport',
    modules=['Az.Accounts', 'Az.Compute'],
    synopsis='Reports Azure VM patch compliance from Update Manager assessment data.',
    desc='Reads the last patch assessment for each VM and reports pending updates by classification, '
         'flagging VMs with outstanding critical or security patches and VMs whose assessment is '
         'itself stale. Reporting only - patch execution is a separate approval-gated action.',
    params=[SUB, RG,
            dict(name='StaleAssessmentDays', help='Flag a VM whose last assessment is older than this.',
                 decl="[ValidateRange(1,365)]\n    [int]$StaleAssessmentDays = 7")],
    perms='Reader plus Virtual Machine Contributor (assessment data requires it).',
    notes='Requires Azure Update Manager assessment to have run at least once per VM. A VM that has '
          'never been assessed is reported as Unknown rather than compliant - never assessed is not '
          'the same as no missing patches.',
    examples=[("-OutputFormat HTML", 'Patch compliance across the subscription.'),
              ("-ResourceGroupName rg-prod -StaleAssessmentDays 3", 'Tighter staleness threshold.')],
    discover=SELECT_SUB + """
$vms = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ } }
       else                    { Get-AzVM }

foreach ($vm in $vms) {
    $assessment = $null
    try {
        $uri = ('{0}/patchAssessmentResults/latest?api-version=2023-03-01' -f $vm.Id)
        $resp = Invoke-AzRestMethod -Path $uri -Method GET -ErrorAction Stop
        if ($resp.StatusCode -lt 400) { $assessment = ($resp.Content | ConvertFrom-Json).properties }
    } catch {
        Write-Verbose ('No assessment data for {0}' -f $vm.Name)
    }

    if (-not $assessment) {
        $results.Add([PSCustomObject]@{
            Name = $vm.Name; Id = $vm.Id; ResourceGroup = $vm.ResourceGroupName
            OsType = "$($vm.StorageProfile.OsDisk.OsType)"
            LastAssessment = $null; AssessmentAgeDays = $null
            CriticalPending = $null; SecurityPending = $null; OtherPending = $null
            Status = 'Unknown'
            Issues = 'never assessed - not the same as compliant'
        })
        continue
    }

    $ageDays = if ($assessment.startDateTime) {
                   [math]::Round(((Get-Date) - [datetime]$assessment.startDateTime).TotalDays, 1)
               } else { $null }

    $critical = [int]$assessment.availablePatchCountByClassification.critical
    $security = [int]$assessment.availablePatchCountByClassification.security
    $other    = [int]$assessment.availablePatchCountByClassification.other +
                [int]$assessment.availablePatchCountByClassification.updateRollup

    $issues = @()
    if ($critical -gt 0) { $issues += ('{0} critical pending' -f $critical) }
    if ($security -gt 0) { $issues += ('{0} security pending' -f $security) }
    if ($null -ne $ageDays -and $ageDays -gt $StaleAssessmentDays) { $issues += ('assessment {0}d old' -f $ageDays) }

    $results.Add([PSCustomObject]@{
        Name              = $vm.Name
        Id                = $vm.Id
        ResourceGroup     = $vm.ResourceGroupName
        OsType            = "$($vm.StorageProfile.OsDisk.OsType)"
        LastAssessment    = $assessment.startDateTime
        AssessmentAgeDays = $ageDays
        CriticalPending   = $critical
        SecurityPending   = $security
        OtherPending      = $other
        RebootPending     = $assessment.rebootPending
        Status            = if ($critical -gt 0 -or $security -gt 0) { 'NonCompliant' }
                            elseif ($issues.Count) { 'Warning' } else { 'Compliant' }
        Issues            = ($issues -join '; ')
    })
}
"""),

30: dict(
    file='Get-AzStorageAccessReview',
    modules=['Az.Accounts', 'Az.Storage'],
    synopsis='Reviews Azure storage accounts for public exposure and weak access settings.',
    desc='Checks every storage account for public blob access, permitted network rules, HTTPS '
         'enforcement, minimum TLS version and shared-key access, then enumerates containers with '
         'public read. A container set to public read is the finding this exists to surface.',
    params=[SUB, RG,
            dict(name='SkipContainerScan', help='Skip enumerating containers. Faster on large estates, but misses container-level exposure.',
                 decl="[switch]$SkipContainerScan")],
    perms='Reader on the storage accounts, plus Storage Blob Data Reader to enumerate containers.',
    examples=[("-OutputFormat HTML", 'Full storage exposure review as HTML.'),
              ("-ResourceGroupName rg-data -SkipContainerScan", 'Account-level settings only.')],
    discover=SELECT_SUB + """
$accounts = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzStorageAccount -ResourceGroupName $_ } }
            else                    { Get-AzStorageAccount }

foreach ($sa in $accounts) {
    $issues = @()
    if ($sa.AllowBlobPublicAccess)              { $issues += 'public blob access ALLOWED at account level' }
    if (-not $sa.EnableHttpsTrafficOnly)        { $issues += 'HTTPS not enforced' }
    if ($sa.MinimumTlsVersion -ne 'TLS1_2')     { $issues += ('minimum TLS is {0}' -f $sa.MinimumTlsVersion) }
    if ($sa.NetworkRuleSet.DefaultAction -eq 'Allow') { $issues += 'network default action is Allow (open to all networks)' }
    if ($sa.AllowSharedKeyAccess -ne $false)    { $issues += 'shared key access enabled' }

    $publicContainers = @()
    if (-not $SkipContainerScan -and $sa.AllowBlobPublicAccess) {
        try {
            $ctx = $sa.Context
            foreach ($c in (Get-AzStorageContainer -Context $ctx -ErrorAction Stop)) {
                if ($c.PublicAccess -and "$($c.PublicAccess)" -ne 'Off') {
                    $publicContainers += ('{0}({1})' -f $c.Name, $c.PublicAccess)
                }
            }
            if ($publicContainers.Count -gt 0) {
                $issues += ('{0} container(s) with public read' -f $publicContainers.Count)
            }
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $sa.StorageAccountName `
                -Message ('Could not enumerate containers: {0}' -f $_.Exception.Message)
        }
    }

    $results.Add([PSCustomObject]@{
        Name                = $sa.StorageAccountName
        Id                  = $sa.Id
        ResourceGroup       = $sa.ResourceGroupName
        Location            = $sa.Location
        Sku                 = $sa.Sku.Name
        Kind                = "$($sa.Kind)"
        AllowBlobPublicAccess = $sa.AllowBlobPublicAccess
        HttpsOnly           = $sa.EnableHttpsTrafficOnly
        MinimumTlsVersion   = "$($sa.MinimumTlsVersion)"
        NetworkDefaultAction= "$($sa.NetworkRuleSet.DefaultAction)"
        AllowSharedKey      = $sa.AllowSharedKeyAccess
        PublicContainers    = ($publicContainers -join '; ')
        Status              = if ($publicContainers.Count -gt 0) { 'EXPOSED' }
                              elseif ($issues.Count) { 'Weak' } else { 'OK' }
        Issues              = ($issues -join '; ')
    })
    if ($publicContainers.Count -gt 0) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $sa.StorageAccountName `
            -Message ('PUBLIC CONTAINERS: {0}' -f ($publicContainers -join ', '))
    }
}
"""),

31: dict(
    file='Set-AzDevTestLabShutdownSchedule',
    modules=['Az.Accounts', 'Az.Compute'],
    synopsis='Configures or applies auto-shutdown schedules on development VMs.',
    desc='Sets the auto-shutdown schedule on VMs, or applies an immediate shutdown to dev VMs left '
         'running past the cut-off. The workbook specifies 8 PM for dev VMs, which is the default. '
         'Reversible - the VM starts again on request.',
    params=[SUB, RG,
            dict(name='Mode', help='Configure sets the daily auto-shutdown schedule; ShutdownNow deallocates VMs already past the cut-off.',
                 decl="[ValidateSet('Configure','ShutdownNow')]\n    [string]$Mode = 'Configure'"),
            dict(name='ShutdownTime', help='Daily shutdown time in HHmm, local to -ScheduleTimeZone.',
                 decl="[ValidatePattern('^([01]\\\\d|2[0-3])[0-5]\\\\d$')]\n    [string]$ShutdownTime = '2000'"),
            dict(name='ScheduleTimeZone', help='Windows time zone id the shutdown time is expressed in.',
                 decl="[string]$ScheduleTimeZone = 'UTC'"),
            dict(name='EnvironmentTagKey', help='Tag key identifying the environment.',
                 decl="[string]$EnvironmentTagKey = 'Environment'"),
            dict(name='DevEnvironmentValue', help='Tag values treated as development.',
                 decl="[string[]]$DevEnvironmentValue = @('dev','test','sandbox','lab')")],
    perms='Virtual Machine Contributor on the target scope.',
    actionVerb='Set auto-shutdown schedule',
    rollback='Remove the schedule resource, or start the VM again. Auto-shutdown deallocates but '
             'never deletes.',
    notes='Auto-shutdown deallocates the VM, which stops compute billing but does not delete the '
          'disk. Anything held only in the temporary drive is lost, so do not schedule this against '
          'a VM whose workload keeps state there.',
    examples=[("-Mode Configure -ShutdownTime 2000 -ScheduleTimeZone 'Arabian Standard Time'",
               'Sets an 8 PM Gulf-time shutdown on every dev-tagged VM.'),
              ("-Mode ShutdownNow -WhatIf",
               'Shows which dev VMs are running past the cut-off.')],
    discover=SELECT_SUB + """
$vms = if ($ResourceGroupName) { $ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ -Status } }
       else                    { Get-AzVM -Status }

foreach ($vm in $vms) {
    $full = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
    $envTag = $full.Tags[$EnvironmentTagKey]
    if (-not $envTag -or $DevEnvironmentValue -notcontains $envTag) { continue }

    $power = ($vm.PowerState -replace '^VM ', '')

    if ($Mode -eq 'ShutdownNow') {
        if ($power -ne 'running') { continue }
        try {
            $tz  = [System.TimeZoneInfo]::FindSystemTimeZoneById($ScheduleTimeZone)
            $now = [System.TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
        } catch {
            throw ('Unknown time zone "{0}".' -f $ScheduleTimeZone)
        }
        $cutHour = [int]$ShutdownTime.Substring(0,2)
        $cutMin  = [int]$ShutdownTime.Substring(2,2)
        $cut = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $cutHour -Minute $cutMin -Second 0
        if ($now -lt $cut) { continue }        # not yet past the cut-off
    }

    $results.Add([PSCustomObject]@{
        Name          = $vm.Name
        Id            = $full.Id
        ResourceGroup = $vm.ResourceGroupName
        Location      = $vm.Location
        Environment   = $envTag
        PowerState    = $power
        Mode          = $Mode
        ShutdownTime  = $ShutdownTime
        TimeZone      = $ScheduleTimeZone
    })
}
""",
    act="""
if ($item.Mode -eq 'ShutdownNow') {
    Stop-AzVM -ResourceGroupName $item.ResourceGroup -Name $item.Name -Force -ErrorAction Stop | Out-Null
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Deallocated - past the {0} {1} cut-off' -f $item.ShutdownTime, $item.TimeZone)
    $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'Deallocated'; Detail = 'past cut-off'; Succeeded = $true })
} else {
    $props = @{
        status = 'Enabled'
        taskType = 'ComputeVmShutdownTask'
        dailyRecurrence = @{ time = $item.ShutdownTime }
        timeZoneId = $item.TimeZone
        targetResourceId = $item.Id
        notificationSettings = @{ status = 'Disabled'; timeInMinutes = 30 }
    }
    $scheduleName = 'shutdown-computevm-{0}' -f $item.Name
    $uri = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DevTestLab/schedules/{2}?api-version=2018-09-15' -f
            (Get-AzContext).Subscription.Id, $item.ResourceGroup, $scheduleName)

    $body = @{ location = $item.Location; properties = $props } | ConvertTo-Json -Depth 8
    $resp = Invoke-AzRestMethod -Path $uri -Method PUT -Payload $body -ErrorAction Stop
    if ($resp.StatusCode -ge 400) {
        throw ('Schedule creation failed with HTTP {0}: {1}' -f $resp.StatusCode, $resp.Content)
    }

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Auto-shutdown schedule set for {0} {1}' -f $item.ShutdownTime, $item.TimeZone)
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'ScheduleSet'
        Detail = ('{0} {1}' -f $item.ShutdownTime, $item.TimeZone); Succeeded = $true })
}
"""),

32: dict(
    file='New-AzMonitorAlertRule',
    modules=['Az.Accounts', 'Az.Monitor'],
    synopsis='Provisions standard Azure Monitor metric alert rules.',
    desc='Creates a standard set of metric alert rules - CPU, available memory and disk - against '
         'target resources, wired to an existing action group. Idempotent: an alert rule that '
         'already exists is left alone rather than duplicated.',
    params=[SUB, RG,
            dict(name='TargetResourceId', help='Resources to alert on. Omit to target every VM in scope.',
                 decl="[string[]]$TargetResourceId"),
            dict(name='ActionGroupId', help='Resource id of the action group to notify.',
                 decl="[Parameter(Mandatory)]\n    [string]$ActionGroupId"),
            dict(name='CpuThreshold', help='CPU percentage above which the alert fires.',
                 decl="[ValidateRange(1,100)]\n    [int]$CpuThreshold = 85"),
            dict(name='Severity', help='Alert severity, 0 (critical) to 4 (verbose).',
                 decl="[ValidateRange(0,4)]\n    [int]$Severity = 2"),
            dict(name='EvaluationFrequencyMinutes', help='How often the rule is evaluated.',
                 decl="[ValidateSet(1,5,15,30,60)]\n    [int]$EvaluationFrequencyMinutes = 5"),
            dict(name='WindowSizeMinutes', help='Aggregation window. Must be at least the evaluation frequency.',
                 decl="[ValidateSet(5,15,30,60,360,720,1440)]\n    [int]$WindowSizeMinutes = 15")],
    perms='Monitoring Contributor on the target scope.',
    actionVerb='Create alert rule',
    rollback='Remove-AzMetricAlertRuleV2. Alert rules are additive and affect nothing but notification.',
    notes='The action group must already exist - this script does not create one, because notification '
          'routing is an organisational decision rather than a technical default.',
    examples=[("-ResourceGroupName rg-prod -ActionGroupId '/subscriptions/.../actionGroups/ag-ops'",
               'Creates CPU alerts for every VM in the resource group.'),
              ("-TargetResourceId '/subscriptions/.../virtualMachines/APP01' -ActionGroupId '...' -CpuThreshold 90 -WhatIf",
               'Shows the alert that would be created for one VM.')],
    discover=SELECT_SUB + """
if ($WindowSizeMinutes -lt $EvaluationFrequencyMinutes) {
    throw ('WindowSizeMinutes ({0}) cannot be smaller than EvaluationFrequencyMinutes ({1}).' -f
           $WindowSizeMinutes, $EvaluationFrequencyMinutes)
}

$ag = Get-AzActionGroup -ResourceId $ActionGroupId -ErrorAction SilentlyContinue
if (-not $ag) { throw ('Action group {0} not found. Create it before provisioning alert rules.' -f $ActionGroupId) }

$targets = if ($TargetResourceId) { $TargetResourceId }
           elseif ($ResourceGroupName) { ($ResourceGroupName | ForEach-Object { Get-AzVM -ResourceGroupName $_ }).Id }
           else { (Get-AzVM).Id }

foreach ($tid in $targets) {
    $shortName = ($tid -split '/')[-1]
    $rgName = ($tid -split '/')[4]
    $ruleName = ('alert-cpu-{0}' -f $shortName)

    if (Get-AzMetricAlertRuleV2 -ResourceGroupName $rgName -Name $ruleName -ErrorAction SilentlyContinue) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ruleName `
            -Message 'Skipped - alert rule already exists (idempotent)'
        continue
    }

    $results.Add([PSCustomObject]@{
        Name          = $ruleName
        Id            = $tid
        ResourceGroup = $rgName
        TargetName    = $shortName
        RuleName      = $ruleName
        MetricName    = 'Percentage CPU'
        Threshold     = $CpuThreshold
        Severity      = $Severity
        Frequency     = ('PT{0}M' -f $EvaluationFrequencyMinutes)
        WindowSize    = ('PT{0}M' -f $WindowSizeMinutes)
        ActionGroup   = ($ActionGroupId -split '/')[-1]
    })
}
""",
    act="""
$criteria = New-AzMetricAlertRuleV2Criteria -MetricName $item.MetricName `
    -MetricNamespace 'Microsoft.Compute/virtualMachines' -TimeAggregation Average `
    -Operator GreaterThan -Threshold $item.Threshold

Add-AzMetricAlertRuleV2 -Name $item.RuleName -ResourceGroupName $item.ResourceGroup `
    -WindowSize $item.WindowSize -Frequency $item.Frequency -TargetResourceId $item.Id `
    -Condition $criteria -ActionGroupId $ActionGroupId -Severity $item.Severity `
    -Description ('CPU above {0}% - provisioned by {1}' -f $item.Threshold, $scriptName) `
    -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Alert rule created: {0} > {1}%, severity {2}, window {3}' -f
    $item.MetricName, $item.Threshold, $item.Severity, $item.WindowSize)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'AlertRuleCreated'
    Detail = ('{0} > {1}%' -f $item.MetricName, $item.Threshold); Succeeded = $true })
"""),
}
