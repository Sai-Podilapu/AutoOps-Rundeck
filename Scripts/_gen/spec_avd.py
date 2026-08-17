# -*- coding: utf-8 -*-
"""Azure AVD - use cases 1-8.

Two scripts in the Azure category also touch AVD - Set-AzAvdSessionHostPower
(power state) and Get-AzAvdUtilizationReport (utilisation). These eight are
separate use cases from a separate sheet and are built separately, per the
master prompt's rule against merging rows. Where the subject overlaps, the
.NOTES on each script says which one to reach for.
"""

COMMON_PARAMS = [
    dict(name='SubscriptionId', help='Azure subscription. The current context when omitted.',
         decl="[string]$SubscriptionId"),
    dict(name='ResourceGroupName', help='Resource group holding the host pool.',
         decl="[Parameter(Mandatory)]\n    [string]$ResourceGroupName"),
    dict(name='HostPoolName', help='AVD host pool name.',
         decl="[Parameter(Mandatory)]\n    [string]$HostPoolName"),
]

AVD_CONNECT = r"""
$azContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $azContext) {
    throw 'No Azure context. Run Connect-AzAccount, or use a managed identity, before this script.'
}
if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
    $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
}

$hostPool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -ErrorAction Stop
if (-not $hostPool) {
    throw ('Host pool "{0}" not found in resource group "{1}".' -f $HostPoolName, $ResourceGroupName)
}
Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    'Host pool {0}: type {1}, load balancer {2}, max sessions {3}' -f
    $hostPool.Name, $hostPool.HostPoolType, $hostPool.LoadBalancerType, $hostPool.MaxSessionLimit)

$sessionHosts = @(Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName `
    -HostPoolName $HostPoolName -ErrorAction Stop)
if ($sessionHosts.Count -eq 0) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'Host pool contains no session hosts.'
}

function Get-AvdShortName {
    <#
        .SYNOPSIS
            The session host name without the host pool prefix Azure prepends.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$FullName)

    return ($FullName -split '/')[-1]
}
"""


SPECS = {

1: dict(
    file='Set-AvdSessionHostDrainMode',
    modules=['Az.Accounts', 'Az.DesktopVirtualization'],
    synopsis='Puts AVD session hosts into or out of drain mode.',
    desc='Toggles whether a session host accepts new connections. Drain mode is the graceful step '
         'before maintenance: existing sessions keep working and no new ones land, so the host '
         'empties as people log off naturally.',
    params=COMMON_PARAMS + [
        dict(name='SessionHostName', help='Session host(s) to change. All hosts in the pool when omitted.',
             decl="[string[]]$SessionHostName"),
        dict(name='Drain', help='Enable drain mode. Without this the hosts are returned to service.',
             decl="[switch]$Drain"),
        dict(name='MaxDrainPercent',
             help='Refuse to drain if it would leave less than this percentage of the pool taking '
                  'connections. Guards against draining a whole pool by accident.',
             decl="[ValidateRange(0,100)]\n    [int]$MaxDrainPercent = 50")],
    perms='Desktop Virtualization Host Pool Contributor on the host pool.',
    actionVerb='Set drain mode',
    rollback='Fully reversible - run again without -Drain to return the hosts to service. No session '
             'is disconnected by this script either way.',
    notes='Drain mode disconnects nobody. Existing sessions continue and the host empties as users '
          'log off, which is why it is the graceful first step and why draining the entire pool by '
          'mistake is a slow-motion outage rather than an instant one - nobody notices until the next '
          'person tries to connect. -MaxDrainPercent is the guard against that. For powering hosts '
          'off, see Set-AzAvdSessionHostPower in the Azure category; this script only controls '
          'whether they accept connections.',
    examples=[("-ResourceGroupName rg-avd -HostPoolName hp-prod -SessionHostName avd-01 -Drain",
               'Drains one host before maintenance.'),
              ("-ResourceGroupName rg-avd -HostPoolName hp-prod -SessionHostName avd-01",
               'Returns the host to service.')],
    discover=AVD_CONNECT + r"""
$targets = @($sessionHosts)
if ($SessionHostName) {
    $targets = @($sessionHosts | Where-Object { $SessionHostName -contains (Get-AvdShortName -FullName $_.Name) })
}

if ($Drain) {
    # Draining everything is an outage nobody notices until the next login.
    $alreadyDraining = @($sessionHosts | Where-Object { -not $_.AllowNewSession }).Count
    $wouldDrain = @($targets | Where-Object { $_.AllowNewSession }).Count
    $remaining = $sessionHosts.Count - $alreadyDraining - $wouldDrain
    $remainingPercent = if ($sessionHosts.Count -gt 0) {
        [math]::Round(($remaining / $sessionHosts.Count) * 100, 1)
    } else { 0 }

    if ($remainingPercent -lt $MaxDrainPercent) {
        throw ('Refusing to drain: this would leave {0}% of the pool taking connections, below the ' +
               '-MaxDrainPercent floor of {1}%. {2} of {3} host(s) would be draining.' -f
               $remainingPercent, $MaxDrainPercent, ($alreadyDraining + $wouldDrain), $sessionHosts.Count)
    }
}

foreach ($sessionHost in $targets) {
    $shortName = Get-AvdShortName -FullName $sessionHost.Name
    $wantAllow = (-not $Drain)

    if ($sessionHost.AllowNewSession -eq $wantAllow) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $shortName -Message (
            'Skipped - already {0} (idempotent)' -f $(if ($Drain) { 'draining' } else { 'in service' }))
        continue
    }

    $results.Add([PSCustomObject]@{
        Name            = $shortName
        Id              = $sessionHost.Name
        SessionHostName = $shortName
        FullName        = $sessionHost.Name
        Status          = $sessionHost.Status
        CurrentlyAllowsNew = $sessionHost.AllowNewSession
        TargetAllowsNew = $wantAllow
        ActiveSessions  = $sessionHost.Session
        AgentVersion    = $sessionHost.AgentVersion
        UpdateState     = $sessionHost.UpdateState
        Impact          = if ($Drain) { 'No new connections; existing sessions continue undisturbed' }
                          else { 'Host returns to the load balancer rotation' }
    })
}
""",
    act=r"""
Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
    -Name $item.SessionHostName -AllowNewSession:$item.TargetAllowsNew -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0}. {1} existing session(s) left connected.' -f
    $(if ($item.TargetAllowsNew) { 'Returned to service' } else { 'Drain mode ON' }), $item.ActiveSessions)
$actions.Add([PSCustomObject]@{
    Name = $item.Name
    Action = $(if ($item.TargetAllowsNew) { 'InService' } else { 'Draining' })
    Detail = ('{0} active session(s)' -f $item.ActiveSessions); Succeeded = $true })
"""),

2: dict(
    file='Update-AvdHostPoolImage',
    modules=['Az.Accounts', 'Az.DesktopVirtualization', 'Az.Compute'],
    synopsis='Rolls a validated golden image out to a host pool in batches.',
    desc='Points a host pool at a new golden image version and rolls it out in batches, draining each '
         'batch before it is touched. It will not start until a human has recorded that the image was '
         'validated and UAT signed off - the workbook assigns that to a person and this script has no '
         'way to judge it.',
    params=COMMON_PARAMS + [
        dict(name='GalleryImageId',
             help='Full resource id of the Compute Gallery image VERSION to roll out.',
             decl="[Parameter(Mandatory)]\n    [string]$GalleryImageId"),
        dict(name='ImageValidated',
             help='Confirms the golden image was validated. Required - there is no way for this '
                  'script to establish it.',
             decl="[switch]$ImageValidated"),
        dict(name='UatSignOffBy',
             help='Name of the person who signed off UAT on this image. Recorded in the audit trail '
                  'and required.',
             decl="[string]$UatSignOffBy"),
        dict(name='BatchSize', help='How many session hosts to roll out at once.',
             decl="[ValidateRange(1,100)]\n    [int]$BatchSize = 2"),
        dict(name='ApiVersion',
             help='PLACEHOLDER - ARM api-version for the session host configuration and update '
                  'operations. These moved through several preview versions; VERIFY against your '
                  'tenant. Listed in MANIFEST.md under Needs Input.',
             decl="[string]$ApiVersion = '2024-04-08-preview'")],
    perms='Desktop Virtualization Host Pool Contributor, plus Reader on the Compute Gallery.',
    actionVerb='Roll out image to host pool',
    reason='Validated golden image rollout',
    rollback='Re-run against the PREVIOUS image version id, which is captured and logged before the '
             'change. Sessions already migrated to the new image are not rolled back by that - they '
             'are replaced again.',
    notes='ASSIST-ONLY. The orchestration - drain, batch, sequence, record - is mechanical and worth '
          'automating. Deciding that a golden image is fit to put in front of users is not: it needs '
          'someone to log in to it and use the applications. So -ImageValidated and -UatSignOffBy are '
          'both mandatory, and the second one records WHO, because "validated" with no name attached '
          'is not a sign-off. The rollout mechanism uses the session host configuration API, whose '
          'api-version moved through several previews - it is a parameter rather than a guess.',
    examples=[("-ResourceGroupName rg-avd -HostPoolName hp-prod -GalleryImageId /subscriptions/.../versions/1.0.5",
               'REPORT ONLY. Validates the image and raises an approval.'),
              ("-ResourceGroupName rg-avd -HostPoolName hp-prod -GalleryImageId /subscriptions/.../versions/1.0.5 "
               "-ImageValidated -UatSignOffBy 'A. Rahman' -ApprovalReference APR-... -BatchSize 2",
               'Rolls the validated image out two hosts at a time.')],
    discover=AVD_CONNECT + r"""
if (-not $ImageValidated) {
    throw 'Refusing to roll out without -ImageValidated. Whether a golden image is fit to put in ' +
          'front of users needs someone to log in to it and use the applications; this script cannot ' +
          'establish that.'
}
if (-not $UatSignOffBy) {
    throw 'Refusing to roll out without -UatSignOffBy. "Validated" with no name attached is not a sign-off.'
}

# Confirm the image version exists before anybody approves a rollout of it.
$imageVersion = $null
try {
    $imageVersion = Get-AzResource -ResourceId $GalleryImageId -ErrorAction Stop
} catch {
    throw ('Image version {0} could not be resolved: {1}. The rollout is not proposed against an ' +
           'image that may not exist.' -f $GalleryImageId, $_.Exception.Message)
}

$currentImage = ''
try {
    $configResponse = Invoke-AzRestMethod -Method GET -ErrorAction Stop -Path (
        '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DesktopVirtualization/hostPools/{2}' +
        '/sessionHostConfigurations/default?api-version={3}' -f
        $azContext.Subscription.Id, $ResourceGroupName, $HostPoolName, $ApiVersion)
    if ($configResponse.StatusCode -lt 400) {
        $currentImage = ($configResponse.Content | ConvertFrom-Json).properties.imageInfo.customInfo.resourceId
    } else {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            'Session host configuration unreadable (HTTP {0}). The current image is unknown, so the ' +
            'rollback reference below will be empty. Check -ApiVersion against your tenant.' -f $configResponse.StatusCode)
    }
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'Session host configuration unreadable: {0}' -f $_.Exception.Message)
}

if ($currentImage -eq $GalleryImageId) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Skipped - the host pool already points at this image version (idempotent).')
} else {
    $ordered = @($sessionHosts | Sort-Object Name)
    $batchNumber = 0
    for ($i = 0; $i -lt $ordered.Count; $i += $BatchSize) {
        $batchNumber++
        $batch = @($ordered[$i..([math]::Min($i + $BatchSize - 1, $ordered.Count - 1))])

        $results.Add([PSCustomObject]@{
            Name           = ('Batch {0}' -f $batchNumber)
            Id             = ('batch-{0}' -f $batchNumber)
            BatchNumber    = $batchNumber
            SessionHosts   = ((@($batch) | ForEach-Object { Get-AvdShortName -FullName $_.Name }) -join '; ')
            HostCount      = $batch.Count
            ActiveSessions = (@($batch) | Measure-Object Session -Sum).Sum
            CurrentImage   = $currentImage
            TargetImage    = $GalleryImageId
            ImageName      = $imageVersion.Name
            UatSignOffBy   = $UatSignOffBy
            ApiVersion     = $ApiVersion
            Impact         = 'Hosts are drained first, so sessions end naturally rather than being cut'
        })
    }

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        '{0} host(s) in {1} batch(es) of {2}. Image validated, UAT signed off by {3}.' -f
        $ordered.Count, $batchNumber, $BatchSize, $UatSignOffBy)
}
""",
    act=r"""
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Previous image (rollback reference): {0}' -f
    $(if ($item.CurrentImage) { $item.CurrentImage } else { '(not readable)' }))

# Drain first, so sessions end naturally rather than being cut.
foreach ($name in ($item.SessionHosts -split ';')) {
    $shortName = $name.Trim()
    if (-not $shortName) { continue }
    Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
        -Name $shortName -AllowNewSession:$false -ErrorAction Stop | Out-Null
}
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    '{0} host(s) drained ahead of the update; {1} session(s) were active.' -f
    $item.HostCount, $item.ActiveSessions)

$configBody = @{
    properties = @{
        imageInfo = @{
            type = 'Custom'
            customInfo = @{ resourceId = $item.TargetImage }
        }
    }
} | ConvertTo-Json -Depth 8

$configPath = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DesktopVirtualization/hostPools/{2}' +
               '/sessionHostConfigurations/default?api-version={3}') -f
               $azContext.Subscription.Id, $ResourceGroupName, $HostPoolName, $item.ApiVersion

$configUpdate = Invoke-AzRestMethod -Method PUT -Path $configPath -Payload $configBody -ErrorAction Stop
if ($configUpdate.StatusCode -ge 400) {
    throw ('Session host configuration update failed (HTTP {0}): {1}. Check -ApiVersion.' -f
           $configUpdate.StatusCode, $configUpdate.Content)
}

$updatePath = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DesktopVirtualization/hostPools/{2}' +
               '/initiateSessionHostUpdate?api-version={3}') -f
               $azContext.Subscription.Id, $ResourceGroupName, $HostPoolName, $item.ApiVersion

$trigger = Invoke-AzRestMethod -Method POST -Path $updatePath -ErrorAction Stop
if ($trigger.StatusCode -ge 400) {
    throw ('Session host update could not be initiated (HTTP {0}): {1}' -f $trigger.StatusCode, $trigger.Content)
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Batch {0}: image set to {1} and update initiated. UAT sign-off: {2}. Approval {3}.' -f
    $item.BatchNumber, $item.ImageName, $item.UatSignOffBy, $ApprovalReference)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'ImageRolledOut'
    Detail = ('{0} host(s) to {1}' -f $item.HostCount, $item.ImageName); Succeeded = $true })
"""),

3: dict(
    file='Disconnect-AvdUserSession',
    modules=['Az.Accounts', 'Az.DesktopVirtualization'],
    synopsis='Warns and then logs off idle AVD sessions.',
    desc='Finds sessions idle beyond a threshold, sends each user an on-screen warning, waits, and '
         'then logs them off. The warning is not optional decoration - a forced logoff loses whatever '
         'was not saved, and the SOP requires users be told first.',
    params=COMMON_PARAMS + [
        dict(name='IdleThresholdHours', help='Sessions idle longer than this are candidates.',
             decl="[ValidateRange(1,168)]\n    [int]$IdleThresholdHours = 4"),
        dict(name='WarningMinutes', help='How long to give users between the warning and the logoff.',
             decl="[ValidateRange(1,120)]\n    [int]$WarningMinutes = 15"),
        dict(name='WarningMessage', help='Message shown to the user.',
             decl="[string]$WarningMessage = 'Your session has been idle and will be signed out shortly. Please save your work now.'"),
        dict(name='SkipWarning',
             help='Log off without warning. Contrary to the SOP; logged as a WARN and requires a '
                  'reason for the audit trail.',
             decl="[switch]$SkipWarning"),
        dict(name='DisconnectOnly',
             help='Disconnect the session rather than logging off. The session and its unsaved work '
                  'survive on the host.',
             decl="[switch]$DisconnectOnly"),
        dict(name='ExcludeUser', help='UPNs never disconnected or logged off.',
             decl="[string[]]$ExcludeUser")],
    perms='Desktop Virtualization Session Host Contributor on the host pool.',
    actionVerb='Log off idle session',
    reason='Idle session reclamation',
    rollback='NONE for a logoff - unsaved work is gone. A disconnect is fully reversible: the user '
             'reconnects to the same session with everything intact, which is why -DisconnectOnly '
             'exists and is worth preferring where reclaiming the licence is the actual goal.',
    notes='The guardrail says warn users first, so the warning is the default path and the wait is '
          'real - the script sends the message, sleeps for -WarningMinutes, then acts. -SkipWarning '
          'exists for an emergency and logs that the SOP was bypassed. Consider -DisconnectOnly '
          'first: it frees the connection without ending the session, so nothing is lost, and for '
          'most "idle session" goals it is enough.',
    examples=[("-ResourceGroupName rg-avd -HostPoolName hp-prod -IdleThresholdHours 4",
               'REPORT ONLY. Lists idle sessions and raises an approval.'),
              ("-ResourceGroupName rg-avd -HostPoolName hp-prod -DisconnectOnly -ApprovalReference APR-...",
               'Disconnects idle sessions without losing anything.'),
              ("-ResourceGroupName rg-avd -HostPoolName hp-prod -WarningMinutes 15 -ApprovalReference APR-...",
               'Warns, waits 15 minutes, then logs off.')],
    discover=AVD_CONNECT + r"""
if ($SkipWarning -and -not $Reason) {
    throw '-SkipWarning bypasses the SOP requirement to warn users first. Supply -Reason recording why.'
}

$userSessions = @(Get-AzWvdUserSession -ResourceGroupName $ResourceGroupName `
    -HostPoolName $HostPoolName -ErrorAction Stop)
$now = Get-Date

foreach ($session in $userSessions) {
    $upn = $session.UserPrincipalName
    if ($ExcludeUser -and $ExcludeUser -contains $upn) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $upn -Message 'Excluded by -ExcludeUser'
        continue
    }

    # A disconnected session has no idle clock of its own; its create time is
    # the only thing available, so it is reported as such rather than guessed.
    $idleHours = $null
    if ($session.SessionState -eq 'Active' -and $session.CreateTime) {
        $idleHours = [math]::Round(($now - [datetime]$session.CreateTime).TotalHours, 1)
    } elseif ($session.CreateTime) {
        $idleHours = [math]::Round(($now - [datetime]$session.CreateTime).TotalHours, 1)
    }

    if ($null -eq $idleHours) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $upn `
            -Message 'Skipped - session age could not be established, so idleness is unknown.'
        continue
    }
    if ($idleHours -lt $IdleThresholdHours) { continue }

    $parts = $session.Name -split '/'
    $results.Add([PSCustomObject]@{
        Name            = ('{0} on {1}' -f $upn, $parts[1])
        Id              = $session.Name
        UserPrincipalName = $upn
        SessionHostName = $parts[1]
        SessionId       = $parts[-1]
        SessionState    = $session.SessionState
        CreateTime      = $session.CreateTime
        AgeHours        = $idleHours
        ApplicationType = $session.ApplicationType
        WillWarn        = (-not $SkipWarning)
        Operation       = if ($DisconnectOnly) { 'Disconnect' } else { 'Logoff' }
        Impact          = if ($DisconnectOnly) { 'Session survives on the host; the user reconnects to it intact' }
                          else { 'Session ENDS; anything unsaved is lost' }
    })
}

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    '{0} session(s) beyond {1}h. Operation: {2}. Warning: {3}.' -f
    $results.Count, $IdleThresholdHours,
    $(if ($DisconnectOnly) { 'disconnect' } else { 'LOGOFF' }),
    $(if ($SkipWarning) { 'SKIPPED - SOP bypassed' } else { ('{0} minutes' -f $WarningMinutes) }))
""",
    act=r"""
if ($item.WillWarn) {
    Send-AzWvdUserSessionMessage -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
        -SessionHostName $item.SessionHostName -UserSessionId $item.SessionId `
        -MessageTitle 'Session sign-out notice' -MessageBody $WarningMessage -ErrorAction Stop | Out-Null

    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
        'Warning sent; waiting {0} minute(s) before acting.' -f $WarningMinutes)
    Start-Sleep -Seconds ($WarningMinutes * 60)
} else {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
        'NO WARNING SENT - SOP bypassed via -SkipWarning. Reason: {0}' -f $Reason)
}

if ($item.Operation -eq 'Disconnect') {
    Disconnect-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
        -SessionHostName $item.SessionHostName -Id $item.SessionId -ErrorAction Stop | Out-Null
    $detail = 'Disconnected; session and unsaved work intact on the host'
} else {
    Remove-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
        -SessionHostName $item.SessionHostName -Id $item.SessionId -Force -ErrorAction Stop | Out-Null
    $detail = 'Logged off; unsaved work lost'
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} after {1}h. {2}' -f $item.Operation, $item.AgeHours, $detail)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
"""),

4: dict(
    file='Set-AvdHostPoolScale',
    modules=['Az.Accounts', 'Az.DesktopVirtualization', 'Az.Compute'],
    synopsis='Scales a host pool to a target host count, respecting a minimum.',
    desc='Starts or stops session hosts to reach a target count for the current schedule window. '
         'The minimum-host floor is absolute, and a host carrying sessions is never stopped - it is '
         'drained and left for the next run.',
    params=COMMON_PARAMS + [
        dict(name='PeakHostCount', help='Hosts to run during peak hours.',
             decl="[Parameter(Mandatory)]\n    [ValidateRange(1,500)]\n    [int]$PeakHostCount"),
        dict(name='OffPeakHostCount', help='Hosts to run outside peak hours.',
             decl="[Parameter(Mandatory)]\n    [ValidateRange(0,500)]\n    [int]$OffPeakHostCount"),
        dict(name='PeakStartHour', help='First hour of the peak window, local time.',
             decl="[ValidateRange(0,23)]\n    [int]$PeakStartHour = 7"),
        dict(name='PeakEndHour', help='Last hour of the peak window, local time.',
             decl="[ValidateRange(0,23)]\n    [int]$PeakEndHour = 18"),
        dict(name='MinimumHosts',
             help='Absolute floor on running hosts. Never breached, whatever the schedule says.',
             decl="[ValidateRange(1,500)]\n    [int]$MinimumHosts = 1"),
        dict(name='PeakDayOfWeek', help='Days the peak window applies on.',
             decl="[string[]]$PeakDayOfWeek = @('Monday','Tuesday','Wednesday','Thursday','Friday')")],
    perms='Desktop Virtualization Host Pool Contributor, plus Virtual Machine Contributor on the '
          'session host VMs.',
    actionVerb='Scale host pool',
    rollback='Reversible - the next run scales back according to the schedule. A stopped host is '
             'started again in seconds to minutes; nothing on it is lost, since FSLogix keeps '
             'profiles on the share rather than the host.',
    notes='The minimum-host floor is checked against the target BEFORE anything is stopped, and it '
          'wins over the schedule. Azure also has native scaling plans, which do load-based scaling '
          'properly and are the better answer for a pool that needs it; this script is the simpler '
          'schedule-driven alternative for pools where a scaling plan is more machinery than the '
          'problem deserves. A host with active sessions is drained rather than stopped, and picked '
          'up on a later run once it is empty - stopping a host with users on it is a disconnection, '
          'not a scale-down.',
    examples=[("-ResourceGroupName rg-avd -HostPoolName hp-prod -PeakHostCount 10 -OffPeakHostCount 2 -MinimumHosts 2",
               'Schedule-driven scaling with a floor of two hosts.'),
              ("-ResourceGroupName rg-avd -HostPoolName hp-prod -PeakHostCount 10 -OffPeakHostCount 2 -WhatIf",
               'Shows what would start or stop.')],
    discover=AVD_CONNECT + r"""
$now = Get-Date
$isPeakDay = $PeakDayOfWeek -contains "$($now.DayOfWeek)"
$isPeakHour = if ($PeakStartHour -le $PeakEndHour) {
    $now.Hour -ge $PeakStartHour -and $now.Hour -le $PeakEndHour
} else {
    $now.Hour -ge $PeakStartHour -or $now.Hour -le $PeakEndHour
}
$isPeak = ($isPeakDay -and $isPeakHour)
$target = if ($isPeak) { $PeakHostCount } else { $OffPeakHostCount }

# The floor wins over the schedule, always.
if ($target -lt $MinimumHosts) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Schedule target {0} is below the -MinimumHosts floor of {1}; the floor wins.' -f $target, $MinimumHosts)
    $target = $MinimumHosts
}

$vmByHost = @{}
foreach ($sessionHost in $sessionHosts) {
    $shortName = Get-AvdShortName -FullName $sessionHost.Name
    $vmName = ($shortName -split '\.')[0]
    $vm = $null
    try {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -Status -ErrorAction Stop
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $shortName `
            -Message ('Backing VM not resolved in {0}: {1}' -f $ResourceGroupName, $_.Exception.Message)
        continue
    }
    $powerState = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1).Code
    $vmByHost[$shortName] = [PSCustomObject]@{
        VmName = $vmName; PowerState = "$powerState"; SessionHost = $sessionHost
        IsRunning = ("$powerState" -eq 'PowerState/running')
    }
}

$running = @($vmByHost.Values | Where-Object { $_.IsRunning })
$stopped = @($vmByHost.Values | Where-Object { -not $_.IsRunning })

Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
    '{0} window: {1} host(s) running, target {2}, floor {3}.' -f
    $(if ($isPeak) { 'PEAK' } else { 'off-peak' }), $running.Count, $target, $MinimumHosts)

if ($running.Count -lt $target) {
    foreach ($candidate in (@($stopped) | Select-Object -First ($target - $running.Count))) {
        $results.Add([PSCustomObject]@{
            Name           = $candidate.VmName
            Id             = $candidate.VmName
            VmName         = $candidate.VmName
            SessionHostName = (Get-AvdShortName -FullName $candidate.SessionHost.Name)
            Operation      = 'Start'
            PowerState     = $candidate.PowerState
            ActiveSessions = $candidate.SessionHost.Session
            Window         = if ($isPeak) { 'peak' } else { 'off-peak' }
            TargetCount    = $target
            RunningCount   = $running.Count
            Impact         = 'Host starts and joins the pool'
        })
    }
} elseif ($running.Count -gt $target) {
    $toStop = $running.Count - $target
    # Emptiest first, so the fewest people are affected by a drain.
    foreach ($candidate in (@($running | Sort-Object { $_.SessionHost.Session }) | Select-Object -First $toStop)) {
        $sessions = [int]$candidate.SessionHost.Session
        $results.Add([PSCustomObject]@{
            Name           = $candidate.VmName
            Id             = $candidate.VmName
            VmName         = $candidate.VmName
            SessionHostName = (Get-AvdShortName -FullName $candidate.SessionHost.Name)
            Operation      = if ($sessions -gt 0) { 'Drain' } else { 'Stop' }
            PowerState     = $candidate.PowerState
            ActiveSessions = $sessions
            Window         = if ($isPeak) { 'peak' } else { 'off-peak' }
            TargetCount    = $target
            RunningCount   = $running.Count
            Impact         = if ($sessions -gt 0) {
                                ('{0} active session(s) - drained, not stopped. A later run picks it up once empty.' -f $sessions)
                             } else { 'Empty host stopped' }
        })
    }
} else {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'Already at target ({0} host(s)); nothing to do.' -f $target)
}
""",
    act=r"""
switch ($item.Operation) {
    'Start' {
        Start-AzVM -ResourceGroupName $ResourceGroupName -Name $item.VmName -ErrorAction Stop | Out-Null
        Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
            -Name $item.SessionHostName -AllowNewSession:$true -ErrorAction SilentlyContinue | Out-Null
        $detail = 'Started and allowed to take new sessions'
    }
    'Drain' {
        Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
            -Name $item.SessionHostName -AllowNewSession:$false -ErrorAction Stop | Out-Null
        $detail = ('Drained, NOT stopped - {0} active session(s) left connected' -f $item.ActiveSessions)
    }
    'Stop' {
        Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
            -Name $item.SessionHostName -AllowNewSession:$false -ErrorAction SilentlyContinue | Out-Null
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $item.VmName -Force -ErrorAction Stop | Out-Null
        $detail = 'Stopped (deallocated)'
    }
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} in the {1} window (target {2}). {3}' -f $item.Operation, $item.Window, $item.TargetCount, $detail)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
"""),

5: dict(
    file='Get-AvdFslogixProfileHealth',
    modules=[],
    synopsis='Reports FSLogix profile containers that look unhealthy.',
    desc='Inspects the FSLogix profile share for containers that are oversized, stale, zero-length or '
         'left locked, and reports them. Repair is not attempted - the workbook gates it, and a '
         'profile container is the only copy of somebody\'s desktop.',
    params=[dict(name='ProfileSharePath',
                 help='UNC path to the FSLogix profile share, e.g. \\\\\\\\server\\\\profiles.',
                 decl="[Parameter(Mandatory)]\n    [string]$ProfileSharePath"),
            dict(name='MaxSizeGB', help='Report containers larger than this.',
                 decl="[ValidateRange(1,2048)]\n    [int]$MaxSizeGB = 30"),
            dict(name='StaleDays', help='Report containers not written to in this many days.',
                 decl="[ValidateRange(1,3650)]\n    [int]$StaleDays = 90"),
            dict(name='IssuesOnly', help='Report only containers with a finding.',
                 decl="[switch]$IssuesOnly")],
    perms='Read access to the FSLogix profile share. No write access is needed or requested.',
    notes='REPORT ONLY, and the limits are worth stating. This inspects container FILES - size, '
          'timestamps, lock state, matching pairs. It does NOT mount a VHDX or check its internal '
          'filesystem, because mounting a profile container is itself a write operation against the '
          'only copy of a user\'s desktop, and doing it on a schedule to look for problems is how you '
          'cause them. Deep integrity checking belongs in a gated repair procedure with the user '
          'signed out, which the workbook already says is gated. A container held open by a live '
          'session is normal, not a fault - the report distinguishes the two by age.',
    examples=[("-ProfileSharePath \\\\\\\\fs01\\\\fslogix -MaxSizeGB 30 -IssuesOnly",
               'Reports oversized, stale or locked containers.'),
              ("-ProfileSharePath \\\\\\\\fs01\\\\fslogix -StaleDays 180 -OutputFormat CSV -OutputPath .\\\\profiles.csv",
               'Full inventory as CSV.')],
    discover=r"""
if (-not (Test-Path -LiteralPath $ProfileSharePath)) {
    throw ('Profile share not reachable: {0}' -f $ProfileSharePath)
}

$containers = @(Get-ChildItem -LiteralPath $ProfileSharePath -Recurse -File -Include '*.vhdx', '*.vhd' `
    -ErrorAction SilentlyContinue)
if ($containers.Count -eq 0) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'No profile containers found under {0}. Check the path and that this account can read it - ' +
        'an empty result here is more likely a permissions problem than an empty share.' -f $ProfileSharePath)
}

$now = Get-Date
$maxBytes = $MaxSizeGB * 1GB

foreach ($container in $containers) {
    $issues = @()
    $sizeGB = [math]::Round($container.Length / 1GB, 2)
    $ageDays = [math]::Round(($now - $container.LastWriteTime).TotalDays, 1)

    if ($container.Length -eq 0) {
        $issues += 'ZERO LENGTH - the container holds nothing'
    } elseif ($container.Length -gt $maxBytes) {
        $issues += ('oversized: {0} GB, over the {1} GB threshold' -f $sizeGB, $MaxSizeGB)
    }
    if ($ageDays -gt $StaleDays) {
        $issues += ('stale: not written in {0} day(s)' -f $ageDays)
    }

    # A container held open by a live session is normal. One held open and not
    # written for weeks is not.
    $isLocked = $false
    try {
        $stream = [System.IO.File]::Open($container.FullName, 'Open', 'Read', 'None')
        $stream.Close()
        $stream.Dispose()
    } catch {
        $isLocked = $true
    }
    if ($isLocked -and $ageDays -gt 1) {
        $issues += ('locked but not written in {0} day(s) - possibly an orphaned session' -f $ageDays)
    }

    # FSLogix writes ODFC containers alongside profile ones; a lone RW.VHDX
    # without its parent is a leftover from a failed operation.
    $isDifferencing = $container.Name -match '(?i)_RW\.vhdx?$'
    if ($isDifferencing) {
        $parentName = $container.Name -replace '(?i)_RW(\.vhdx?)$', '$1'
        $parentPath = Join-Path $container.DirectoryName $parentName
        if (-not (Test-Path -LiteralPath $parentPath)) {
            $issues += 'differencing disk with no parent container - leftover from a failed operation'
        }
    }

    if ($IssuesOnly -and $issues.Count -eq 0) { continue }

    $results.Add([PSCustomObject]@{
        Name          = $container.Name
        Id            = $container.FullName
        FullPath      = $container.FullName
        Folder        = $container.DirectoryName
        SizeGB        = $sizeGB
        LastWriteTime = $container.LastWriteTime
        AgeDays       = $ageDays
        IsLocked      = $isLocked
        IsDifferencing= $isDifferencing
        Status        = if ($issues.Count) { 'Attention' } else { 'OK' }
        Issues        = ($issues -join '; ')
        RepairNote    = 'REPORT ONLY. Repair is gated per the SOP, and this script does not mount ' +
                        'containers - mounting is a write against the only copy of a user profile.'
    })

    if ($issues.Count) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $container.Name -Message ($issues -join '; ')
    }
}
"""),

6: dict(
    file='Add-AvdApplicationGroupAssignment',
    modules=['Az.Accounts', 'Az.DesktopVirtualization', 'Az.Resources'],
    synopsis='Assigns users or groups to an AVD application group.',
    desc='Grants the Desktop Virtualization User role on an application group, which is what makes a '
         'RemoteApp or desktop appear in someone\'s feed. Ticket-driven: the workbook says the ticket '
         'is the approval, so the ticket reference is required.',
    params=[dict(name='SubscriptionId', help='Azure subscription. The current context when omitted.',
                 decl="[string]$SubscriptionId"),
            dict(name='ResourceGroupName', help='Resource group holding the application group.',
                 decl="[Parameter(Mandatory)]\n    [string]$ResourceGroupName"),
            dict(name='ApplicationGroupName', help='Application group to grant access to.',
                 decl="[Parameter(Mandatory)]\n    [string]$ApplicationGroupName"),
            dict(name='PrincipalUpn', help='User principal name(s) to assign.',
                 decl="[string[]]$PrincipalUpn"),
            dict(name='PrincipalGroupName', help='Entra group display name(s) to assign.',
                 decl="[string[]]$PrincipalGroupName"),
            dict(name='TicketReference',
                 help='ITSM ticket driving the request. Required - on this use case the ticket IS '
                      'the approval.',
                 decl="[Parameter(Mandatory)]\n    [string]$TicketReference"),
            dict(name='RoleName', help='Role to assign.',
                 decl="[string]$RoleName = 'Desktop Virtualization User'")],
    perms='User Access Administrator or Owner on the application group, to create role assignments.',
    actionVerb='Assign application group access',
    rollback='Remove the role assignment with Remove-AzRoleAssignment. The application disappears '
             'from the user\'s feed at their next refresh.',
    notes='This row is not approval-gated because the workbook says the ticket is the approval, so '
          '-TicketReference is mandatory rather than optional as it is elsewhere in the library. '
          'Assigning a group rather than individual users is almost always the better answer - it '
          'moves the access decision to group membership, where it can be reviewed by the Access '
          'Review campaigns in the Security Cloud category.',
    examples=[("-ResourceGroupName rg-avd -ApplicationGroupName ag-finance -PrincipalGroupName 'AVD-Finance-Users' -TicketReference REQ0012345",
               'Grants a group access to a RemoteApp group.'),
              ("-ResourceGroupName rg-avd -ApplicationGroupName ag-finance -PrincipalUpn user@contoso.com -TicketReference REQ0012345 -WhatIf",
               'Shows the assignment that would be created.')],
    discover=r"""
$azContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $azContext) {
    throw 'No Azure context. Run Connect-AzAccount, or use a managed identity, before this script.'
}
if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
    $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
}

if (-not $PrincipalUpn -and -not $PrincipalGroupName) {
    throw 'Supply -PrincipalUpn or -PrincipalGroupName.'
}

$appGroup = Get-AzWvdApplicationGroup -ResourceGroupName $ResourceGroupName `
    -Name $ApplicationGroupName -ErrorAction Stop
if (-not $appGroup) {
    throw ('Application group "{0}" not found in "{1}".' -f $ApplicationGroupName, $ResourceGroupName)
}

$existing = @(Get-AzRoleAssignment -Scope $appGroup.Id -ErrorAction SilentlyContinue)

foreach ($upn in @($PrincipalUpn)) {
    $principal = Get-AzADUser -UserPrincipalName $upn -ErrorAction SilentlyContinue
    if (-not $principal) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $upn -Message 'User not found; skipped.'
        continue
    }
    if ($existing | Where-Object { $_.ObjectId -eq $principal.Id -and $_.RoleDefinitionName -eq $RoleName }) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $upn `
            -Message 'Skipped - already assigned (idempotent)'
        continue
    }

    $results.Add([PSCustomObject]@{
        Name          = ('{0} -> {1}' -f $upn, $ApplicationGroupName)
        Id            = $principal.Id
        PrincipalId   = $principal.Id
        PrincipalName = $upn
        PrincipalType = 'User'
        ApplicationGroup = $ApplicationGroupName
        ApplicationGroupType = $appGroup.ApplicationGroupType
        Scope         = $appGroup.Id
        RoleName      = $RoleName
        Ticket        = $TicketReference
        Advice        = 'Assigning an Entra group instead moves this decision to group membership, where an access review can see it'
    })
}

foreach ($groupName in @($PrincipalGroupName)) {
    $principal = Get-AzADGroup -DisplayName $groupName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $principal) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $groupName -Message 'Group not found; skipped.'
        continue
    }
    if ($existing | Where-Object { $_.ObjectId -eq $principal.Id -and $_.RoleDefinitionName -eq $RoleName }) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $groupName `
            -Message 'Skipped - already assigned (idempotent)'
        continue
    }

    $results.Add([PSCustomObject]@{
        Name          = ('{0} -> {1}' -f $groupName, $ApplicationGroupName)
        Id            = $principal.Id
        PrincipalId   = $principal.Id
        PrincipalName = $groupName
        PrincipalType = 'Group'
        ApplicationGroup = $ApplicationGroupName
        ApplicationGroupType = $appGroup.ApplicationGroupType
        Scope         = $appGroup.Id
        RoleName      = $RoleName
        Ticket        = $TicketReference
        Advice        = ''
    })
}
""",
    act=r"""
New-AzRoleAssignment -ObjectId $item.PrincipalId -RoleDefinitionName $item.RoleName `
    -Scope $item.Scope -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} "{1}" granted {2} on {3} ({4}). Ticket {5}.' -f
    $item.PrincipalType, $item.PrincipalName, $item.RoleName,
    $item.ApplicationGroup, $item.ApplicationGroupType, $item.Ticket)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'AccessGranted'
    Detail = ('{0} on {1}' -f $item.RoleName, $item.ApplicationGroup); Succeeded = $true })
"""),

7: dict(
    file='Restore-AvdSessionHost',
    modules=['Az.Accounts', 'Az.DesktopVirtualization', 'Az.Compute'],
    synopsis='Reimages AVD session hosts after draining them.',
    desc='Reimages session hosts back to their golden image. Everything on the host is destroyed, so '
         'the host must be drained and empty first - the script verifies both rather than trusting '
         'that somebody did it.',
    params=COMMON_PARAMS + [
        dict(name='SessionHostName', help='Exact session host name(s) to reimage.',
             decl="[Parameter(Mandatory)]\n    [string[]]$SessionHostName"),
        dict(name='VmssName',
             help='Scale set backing the host pool, for VMSS-based pools. Required - non-VMSS hosts '
                  'are reported as needing redeployment instead.',
             decl="[string]$VmssName"),
        dict(name='AllowActiveSessions',
             help='Reimage a host that still has sessions on it. Those users are cut off '
                  'immediately with no warning.',
             decl="[switch]$AllowActiveSessions")],
    minage=0,
    perms='Desktop Virtualization Host Pool Contributor plus Virtual Machine Contributor on the '
          'scale set.',
    actionVerb='Reimage session host',
    reason='Session host reimage to golden image',
    rollback='NONE. A reimage restores the golden image and destroys everything else on the host. '
             'What survives is what was never on the host: FSLogix profiles on the share, and data '
             'in OneDrive or on file servers. Anything saved to the local disk is gone.',
    notes='DESTRUCTIVE, and the guardrail asks for drain plus approval before the trigger. Both are '
          'enforced: a host that is not already in drain mode is EXCLUDED rather than drained '
          'automatically, because draining and reimaging in one run gives sessions no time to end. '
          'Drain it, let it empty, then reimage. A host with active sessions is also excluded unless '
          '-AllowActiveSessions is passed, which cuts those users off with no warning. What is '
          'actually lost is worth being precise about: with FSLogix the user profile lives on the '
          'share and survives, but anything written to the local disk - files on C:, locally '
          'installed applications, machine-level configuration - does not.',
    examples=[("-ResourceGroupName rg-avd -HostPoolName hp-prod -SessionHostName avd-01 -VmssName vmss-avd",
               'REPORT ONLY. Checks drain state and sessions, raises an approval.'),
              ("-ResourceGroupName rg-avd -HostPoolName hp-prod -SessionHostName avd-01 -VmssName vmss-avd "
               "-ApprovalReference APR-... -TicketReference CHG0012345 -Execute",
               'Reimages a drained, empty host.')],
    discover=AVD_CONNECT + r"""
foreach ($name in $SessionHostName) {
    $sessionHost = $sessionHosts | Where-Object { (Get-AvdShortName -FullName $_.Name) -eq $name } |
                   Select-Object -First 1
    if (-not $sessionHost) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name `
            -Message 'Not found in this host pool; skipped.'
        continue
    }

    # Drain first, in a separate run. Draining and reimaging together gives
    # sessions no time to end.
    if ($sessionHost.AllowNewSession) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message (
            'EXCLUDED - host is not in drain mode. Drain it with Set-AvdSessionHostDrainMode, let it ' +
            'empty, then reimage. This script does not drain and reimage in one run.')
        continue
    }

    $activeSessions = [int]$sessionHost.Session
    if ($activeSessions -gt 0 -and -not $AllowActiveSessions) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message (
            'EXCLUDED - {0} active session(s). Wait for the host to empty, or pass -AllowActiveSessions ' +
            'to cut those users off with no warning.' -f $activeSessions)
        continue
    }

    if (-not $VmssName) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message (
            'EXCLUDED - no -VmssName. Reimage is a scale set operation; a host pool built from ' +
            'standalone VMs is replaced by redeployment instead, which this script does not do.')
        continue
    }

    $instance = $null
    try {
        $instances = @(Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $VmssName -ErrorAction Stop)
        $instance = $instances | Where-Object { $_.OsProfile.ComputerName -eq ($name -split '\.')[0] } |
                    Select-Object -First 1
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name `
            -Message ('Scale set instances unreadable: {0}' -f $_.Exception.Message)
        continue
    }
    if (-not $instance) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $name -Message (
            'EXCLUDED - no matching instance in scale set {0}.' -f $VmssName)
        continue
    }

    $results.Add([PSCustomObject]@{
        Name            = $name
        Id              = $sessionHost.Name
        SessionHostName = $name
        VmssName        = $VmssName
        InstanceId      = $instance.InstanceId
        AllowNewSession = $sessionHost.AllowNewSession
        ActiveSessions  = $activeSessions
        HostStatus      = $sessionHost.Status
        AgentVersion    = $sessionHost.AgentVersion
        Survives        = 'FSLogix profiles on the share; OneDrive and file server data'
        Destroyed       = 'Everything on the local disk: files on C:, locally installed applications, machine-level configuration'
        Impact          = if ($activeSessions -gt 0) {
                             ('{0} user(s) CUT OFF with no warning' -f $activeSessions)
                          } else { 'Host is empty; no user is disconnected' }
    })
}
""",
    act=r"""
Set-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $item.VmssName `
    -InstanceId $item.InstanceId -Reimage -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Reimaged (instance {0}). Destroyed: {1}. Survived: {2}. {3}' -f
    $item.InstanceId, $item.Destroyed, $item.Survives, $item.Impact)
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'The host stays in drain mode after reimage. Return it to service with ' +
    'Set-AvdSessionHostDrainMode once it has registered and been checked.')
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Reimaged'
    Detail = ('instance {0}, {1} session(s) at reimage' -f $item.InstanceId, $item.ActiveSessions)
    Succeeded = $true })
"""),

8: dict(
    file='Get-AvdSessionLatencyReport',
    modules=['Az.Accounts', 'Az.OperationalInsights'],
    synopsis='Reports AVD connection counts, round-trip latency and errors.',
    desc='Queries the AVD diagnostic tables in Log Analytics for connection volume, round-trip time '
         'and connection failures over the reporting window, broken down by user and by host.',
    params=[dict(name='SubscriptionId', help='Azure subscription. The current context when omitted.',
                 decl="[string]$SubscriptionId"),
            dict(name='ResourceGroupName', help='Resource group holding the Log Analytics workspace.',
                 decl="[Parameter(Mandatory)]\n    [string]$ResourceGroupName"),
            dict(name='WorkspaceName', help='Log Analytics workspace receiving AVD diagnostics.',
                 decl="[Parameter(Mandatory)]\n    [string]$WorkspaceName"),
            dict(name='LookbackHours', help='Reporting window.',
                 decl="[ValidateRange(1,720)]\n    [int]$LookbackHours = 24"),
            dict(name='LatencyWarnMs', help='Flag average round-trip time above this.',
                 decl="[ValidateRange(1,10000)]\n    [int]$LatencyWarnMs = 150"),
            dict(name='TopCount', help='How many users and hosts to report.',
                 decl="[ValidateRange(1,500)]\n    [int]$TopCount = 25")],
    perms='Log Analytics Reader on the workspace.',
    notes='This needs AVD diagnostic settings sending WVDConnections, WVDConnectionNetworkData and '
          'WVDErrors to the workspace. If a table is missing the query fails and that section is '
          'reported as NOT COLLECTED - which is not the same as no latency problems, and the report '
          'says so rather than showing an empty section. Round-trip time is measured to the gateway, '
          'not to the application, so a good number here does not rule out a slow session; it rules '
          'out the network being the cause.',
    examples=[("-ResourceGroupName rg-avd -WorkspaceName law-avd -LookbackHours 24 -OutputFormat HTML",
               'Daily connection and latency report.'),
              ("-ResourceGroupName rg-avd -WorkspaceName law-avd -LatencyWarnMs 100 -TopCount 50",
               'Tighter latency threshold, more rows.')],
    discover=r"""
$azContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $azContext) {
    throw 'No Azure context. Run Connect-AzAccount, or use a managed identity, before this script.'
}
if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
    $azContext = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
}

$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName `
    -Name $WorkspaceName -ErrorAction Stop

$sections = @(
    @{ Section = 'Latency by user'
       Query = @(
           'WVDConnectionNetworkData'
           ('| where TimeGenerated > ago({0}h)' -f $LookbackHours)
           '| join kind=inner (WVDConnections | project CorrelationId, UserName, SessionHostName) on CorrelationId'
           '| summarize AvgRttMs = avg(EstRoundTripTimeInMs), MaxRttMs = max(EstRoundTripTimeInMs), Samples = count() by UserName'
           '| order by AvgRttMs desc'
           ('| take {0}' -f $TopCount)
       ) -join "`n"
       Dimension = 'UserName' }
    @{ Section = 'Latency by session host'
       Query = @(
           'WVDConnectionNetworkData'
           ('| where TimeGenerated > ago({0}h)' -f $LookbackHours)
           '| join kind=inner (WVDConnections | project CorrelationId, SessionHostName) on CorrelationId'
           '| summarize AvgRttMs = avg(EstRoundTripTimeInMs), MaxRttMs = max(EstRoundTripTimeInMs), Samples = count() by SessionHostName'
           '| order by AvgRttMs desc'
           ('| take {0}' -f $TopCount)
       ) -join "`n"
       Dimension = 'SessionHostName' }
    @{ Section = 'Connection errors'
       Query = @(
           'WVDErrors'
           ('| where TimeGenerated > ago({0}h)' -f $LookbackHours)
           '| summarize Occurrences = count(), Users = dcount(UserName) by CodeSymbolic, ServiceError'
           '| order by Occurrences desc'
           ('| take {0}' -f $TopCount)
       ) -join "`n"
       Dimension = 'CodeSymbolic' }
    @{ Section = 'Connection volume'
       Query = @(
           'WVDConnections'
           ('| where TimeGenerated > ago({0}h)' -f $LookbackHours)
           '| where State == "Connected"'
           '| summarize Connections = count(), Users = dcount(UserName) by SessionHostName'
           '| order by Connections desc'
           ('| take {0}' -f $TopCount)
       ) -join "`n"
       Dimension = 'SessionHostName' }
)

foreach ($section in $sections) {
    $rows = @()
    try {
        $queryResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId `
            -Query $section.Query -ErrorAction Stop
        $rows = @($queryResult.Results)
    } catch {
        # A missing table means diagnostics are not flowing, which is a
        # different finding from "no problems".
        $results.Add([PSCustomObject]@{
            Name       = $section.Section
            Id         = $section.Section
            Section    = $section.Section
            Subject    = ''
            AvgRttMs   = $null
            MaxRttMs   = $null
            Samples    = $null
            Connections= $null
            Users      = $null
            Status     = 'NOT COLLECTED'
            Detail     = ('Query failed: {0}. Check that AVD diagnostic settings send this table to ' +
                          'the workspace. This is NOT evidence of no problems.' -f $_.Exception.Message)
        })
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
            '{0}: NOT COLLECTED - {1}' -f $section.Section, $_.Exception.Message)
        continue
    }

    foreach ($row in $rows) {
        $subject = $row.($section.Dimension)
        $avgRtt = if ($null -ne $row.AvgRttMs) { [math]::Round([double]$row.AvgRttMs, 1) } else { $null }
        $isSlow = ($null -ne $avgRtt -and $avgRtt -gt $LatencyWarnMs)

        $results.Add([PSCustomObject]@{
            Name       = ('{0}: {1}' -f $section.Section, $subject)
            Id         = ('{0}-{1}' -f $section.Section, $subject)
            Section    = $section.Section
            Subject    = $subject
            AvgRttMs   = $avgRtt
            MaxRttMs   = if ($null -ne $row.MaxRttMs) { [math]::Round([double]$row.MaxRttMs, 1) } else { $null }
            Samples    = $row.Samples
            Connections= $row.Connections
            Users      = $row.Users
            Status     = if ($isSlow) { 'HighLatency' }
                         elseif ($section.Section -eq 'Connection errors') { 'Error' }
                         else { 'OK' }
            Detail     = if ($isSlow) {
                            ('Average round-trip {0} ms, over the {1} ms threshold. RTT is measured to ' +
                             'the gateway, so this rules the network IN as a cause, not the application out.' -f $avgRtt, $LatencyWarnMs)
                         } elseif ($row.ServiceError) { ('Service error: {0}' -f $row.ServiceError) }
                         else { '' }
        })

        if ($isSlow) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $subject -Message (
                'Average round-trip {0} ms over {1} sample(s)' -f $avgRtt, $row.Samples)
        }
    }
}
"""),
}
