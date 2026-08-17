# -*- coding: utf-8 -*-
"""M365 - use cases 1-11. Microsoft Graph SDK."""

def graph(scopes):
    return ("\nConnect-MgGraph -Scopes '%s' -NoWelcome -ErrorAction Stop\n"
            "Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'\n" % scopes)

SPECS = {

1: dict(
    file='New-TeamsChannel',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Teams'],
    synopsis='Creates a Teams channel in an existing team from an ITSM request.',
    desc='Creates a standard or private channel. The ticket is the approval for this row, so the '
         'script requires a ticket reference and records it, but does not raise a separate approval '
         'artifact.',
    params=[dict(name='TeamName', help='Display name or id of the team to create the channel in.',
                 decl="[Parameter(Mandatory)]\n    [string]$TeamName"),
            dict(name='ChannelName', help='Channel display name.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$ChannelName"),
            dict(name='ChannelType', help='Standard is visible to all team members; Private is restricted to its own members.',
                 decl="[ValidateSet('Standard','Private')]\n    [string]$ChannelType = 'Standard'"),
            dict(name='Description', help='Channel description.',
                 decl="[string]$Description"),
            dict(name='Owner', help='Owner UPN. Required for a private channel.',
                 decl="[string]$Owner"),
            dict(name='TicketReference', help='ITSM ticket driving the request. Recorded in the audit trail.',
                 decl="[Parameter(Mandatory)]\n    [string]$TicketReference")],
    perms='Microsoft Graph Channel.Create and Group.Read.All.',
    actionVerb='Create Teams channel',
    rollback='Remove the channel. A deleted channel is recoverable for 30 days, but its files live '
             'in the SharePoint site and are removed with it.',
    notes='A private channel gets its own SharePoint site collection and does not inherit the '
          'team\\u2019s permissions. That isolation is the point, but it also means the team owners '
          'cannot see its content - choose Standard unless isolation is genuinely required.',
    examples=[("-TeamName 'Finance' -ChannelName 'Budget-2027' -TicketReference REQ0012345",
               'Creates a standard channel.'),
              ("-TeamName 'Finance' -ChannelName 'Audit' -ChannelType Private -Owner lead@contoso.com -TicketReference REQ0012345",
               'Creates a private channel with an owner.')],
    discover=graph("Group.Read.All','Channel.ReadBasic.All','ChannelSettings.ReadWrite.All") + """
$team = Get-MgGroup -Filter ("displayName eq '{0}'" -f ($TeamName -replace "'", "''")) -ErrorAction SilentlyContinue |
        Where-Object { $_.ResourceProvisioningOptions -contains 'Team' } | Select-Object -First 1
if (-not $team) { $team = Get-MgGroup -GroupId $TeamName -ErrorAction SilentlyContinue }
if (-not $team) { throw ('Team "{0}" not found, or the group is not Teams-enabled.' -f $TeamName) }

if ($ChannelType -eq 'Private' -and -not $Owner) {
    throw 'A private channel requires -Owner. Graph will not create one without an initial owner.'
}

$existing = @(Get-MgTeamChannel -TeamId $team.Id -ErrorAction SilentlyContinue)

foreach ($name in $ChannelName) {
    if ($existing.DisplayName -contains $name) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $name `
            -Message 'Skipped - channel already exists (idempotent)'
        continue
    }
    $results.Add([PSCustomObject]@{
        Name        = ('{0} / {1}' -f $team.DisplayName, $name)
        Id          = $team.Id
        TeamName    = $team.DisplayName
        TeamId      = $team.Id
        ChannelName = $name
        ChannelType = $ChannelType
        Description = $Description
        Owner       = $Owner
        Ticket      = $TicketReference
        Isolation   = if ($ChannelType -eq 'Private') { 'Private - own SharePoint site, invisible to team owners' }
                      else { 'Standard - visible to all team members' }
    })
}
""",
    act="""
$body = @{
    displayName = $item.ChannelName
    description = $item.Description
    membershipType = $item.ChannelType.ToLower()
}
if ($item.ChannelType -eq 'Private') {
    $body.members = @(@{
        '@odata.type' = '#microsoft.graph.aadUserConversationMember'
        'user@odata.bind' = ('https://graph.microsoft.com/v1.0/users(''{0}'')' -f $item.Owner)
        roles = @('owner')
    })
}

New-MgTeamChannel -TeamId $item.TeamId -BodyParameter $body -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} channel created in {1}. Ticket={2}. {3}' -f
    $item.ChannelType, $item.TeamName, $item.Ticket, $item.Isolation)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'ChannelCreated'; Detail = $item.ChannelType; Succeeded = $true })
"""),

2: dict(
    file='Remove-TeamsInactiveChannel',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Teams'],
    synopsis='Archives or deletes Teams channels with no recent activity.',
    desc='Finds channels with no message activity beyond the threshold. The workbook is explicit '
         'about the order of operations: archive first, and delete only after owner confirmation. '
         'This script therefore defaults to ARCHIVE, and deletion requires both approval and an '
         'explicit switch.',
    params=[dict(name='TeamName', help='Limit to specific teams. All Teams-enabled groups when omitted.',
                 decl="[string[]]$TeamName"),
            dict(name='Mode', help='Archive renames the channel with an archive prefix; Delete removes it. Archive is the default per the SOP.',
                 decl="[ValidateSet('Archive','Delete')]\n    [string]$Mode = 'Archive'"),
            dict(name='ArchivePrefix', help='Prefix applied to an archived channel name.',
                 decl="[string]$ArchivePrefix = 'ARCHIVED-'"),
            dict(name='OwnerConfirmed', help='Confirms the channel owner agreed to deletion. Required for -Mode Delete.',
                 decl="[switch]$OwnerConfirmed")],
    minage=90,
    perms='Microsoft Graph Channel.ReadBasic.All, ChannelMessage.Read.All and ChannelSettings.ReadWrite.All. Delete additionally needs Channel.Delete.All.',
    actionVerb='Archive or delete inactive channel',
    reason='Inactive Teams channel cleanup',
    rollback='An archived channel is simply renamed and can be renamed back. A DELETED channel is '
             'recoverable for 30 days, after which its files are gone with it.',
    notes='The General channel cannot be deleted or renamed and is always excluded. Activity is '
          'measured from the most recent message; a channel used only for file storage will look '
          'inactive even though its content is in use, which is why owner confirmation is required '
          'before deletion.',
    examples=[("-MinimumAgeDays 90",
               'REPORT ONLY. Lists channels with no messages in 90 days and raises an approval.'),
              ("-MinimumAgeDays 90 -Mode Delete -OwnerConfirmed -ApprovalReference APR-... -Execute",
               'Deletes the approved channels after owner confirmation.')],
    discover=graph("Group.Read.All','Channel.ReadBasic.All','ChannelMessage.Read.All") + """
if ($Mode -eq 'Delete' -and -not $OwnerConfirmed) {
    throw 'Refusing to delete without -OwnerConfirmed. The SOP requires archiving first and ' +
          'deleting only after the channel owner confirms.'
}

$teams = if ($TeamName) {
             $TeamName | ForEach-Object {
                 Get-MgGroup -Filter ("displayName eq '{0}'" -f ($_ -replace "'", "''")) -ErrorAction SilentlyContinue |
                 Select-Object -First 1
             }
         } else {
             Get-MgGroup -Filter "resourceProvisioningOptions/Any(x:x eq 'Team')" -All -ErrorAction Stop
         }

$cutoff = (Get-Date).AddDays(-$MinimumAgeDays)

foreach ($team in $teams) {
    if (-not $team) { continue }
    $channels = @(Get-MgTeamChannel -TeamId $team.Id -ErrorAction SilentlyContinue)

    foreach ($ch in $channels) {
        # General cannot be renamed or deleted.
        if ($ch.DisplayName -eq 'General') { continue }
        if ($ch.DisplayName -like ("{0}*" -f $ArchivePrefix)) { continue }   # already archived

        $lastMessage = $null
        try {
            $msgs = Get-MgTeamChannelMessage -TeamId $team.Id -ChannelId $ch.Id -Top 1 `
                    -Sort 'createdDateTime desc' -ErrorAction Stop
            $lastMessage = ($msgs | Select-Object -First 1).CreatedDateTime
        } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $ch.DisplayName `
                -Message ('Message history unreadable: {0}' -f $_.Exception.Message)
            continue    # unknown activity is not evidence of inactivity
        }

        $effectiveDate = if ($lastMessage) { $lastMessage } else { $ch.CreatedDateTime }
        if ($effectiveDate -ge $cutoff) { continue }

        $results.Add([PSCustomObject]@{
            Name         = ('{0} / {1}' -f $team.DisplayName, $ch.DisplayName)
            Id           = $ch.Id
            TeamName     = $team.DisplayName
            TeamId       = $team.Id
            ChannelId    = $ch.Id
            ChannelName  = $ch.DisplayName
            MembershipType = "$($ch.MembershipType)"
            CreatedAt    = $effectiveDate
            LastMessage  = $lastMessage
            InactiveDays = [math]::Round(((Get-Date) - $effectiveDate).TotalDays, 0)
            Mode         = $Mode
            FilesCaveat  = 'A channel used only for file storage looks inactive but its content may be in use'
        })
    }
}
""",
    act="""
if ($item.Mode -eq 'Archive') {
    $newName = '{0}{1}' -f $ArchivePrefix, $item.ChannelName
    Update-MgTeamChannel -TeamId $item.TeamId -ChannelId $item.ChannelId `
        -DisplayName $newName -ErrorAction Stop | Out-Null
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Channel archived (renamed to {0}). Inactive {1}d. Reversible by renaming back.' -f
        $newName, $item.InactiveDays)
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'Archived'; Detail = $newName; Succeeded = $true })
} else {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
        'DELETING channel. Inactive {0}d. OwnerConfirmed=true Approval={1}. Files go with it; ' +
        'recoverable for 30 days.' -f $item.InactiveDays, $ApprovalReference)
    Remove-MgTeamChannel -TeamId $item.TeamId -ChannelId $item.ChannelId -ErrorAction Stop
    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message 'Channel deleted'
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'Deleted'
        Detail = ('inactive {0}d; 30-day recovery window' -f $item.InactiveDays); Succeeded = $true })
}
"""),

3: dict(
    file='New-SharePointSite',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Sites'],
    synopsis='Provisions a SharePoint site from a template.',
    desc='Creates a SharePoint site with an owner and a storage quota. Naming and ownership are '
         'enforced in code: an unowned site is one nobody governs, and it is usually discovered '
         'during an audit rather than before.',
    params=[dict(name='SiteName', help='Site display name.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$SiteName"),
            dict(name='SiteAlias', help='URL alias. Derived from the name when omitted.',
                 decl="[string]$SiteAlias"),
            dict(name='Owner', help='Site owner UPN. Required.',
                 decl="[Parameter(Mandatory)]\n    [string]$Owner"),
            dict(name='Template', help='Team site (group-connected) or Communication site.',
                 decl="[ValidateSet('Team','Communication')]\n    [string]$Template = 'Team'"),
            dict(name='Description', help='Site description.',
                 decl="[string]$Description"),
            dict(name='NamingPattern', help='Wildcard pattern the site name must match. Set to * to disable.',
                 decl="[string]$NamingPattern = '*'"),
            dict(name='TicketReference', help='ITSM ticket driving the request.',
                 decl="[Parameter(Mandatory)]\n    [string]$TicketReference")],
    perms='Microsoft Graph Sites.FullControl.All and Group.ReadWrite.All for group-connected sites.',
    actionVerb='Provision SharePoint site',
    rollback='Delete the site. A deleted site is recoverable from the recycle bin for 93 days, '
             'after which it and its content are permanently removed.',
    notes='A Team site creates a Microsoft 365 group with a mailbox, a Planner plan and a Teams '
          'entitlement. A Communication site does not. Choosing Team when only a document library '
          'was wanted creates four objects to govern instead of one.',
    examples=[("-SiteName 'Project Falcon' -Owner lead@contoso.com -TicketReference REQ0012345",
               'Creates a group-connected team site.'),
              ("-SiteName 'Policies' -Owner lead@contoso.com -Template Communication -TicketReference REQ0012345",
               'Creates a communication site with no group.')],
    discover=graph("Sites.FullControl.All','Group.ReadWrite.All','User.Read.All") + """
$ownerUser = Get-MgUser -UserId $Owner -Property Id,UserPrincipalName -ErrorAction Stop

foreach ($name in $SiteName) {
    if ($NamingPattern -ne '*' -and $name -notlike $NamingPattern) {
        throw ('Refusing to create "{0}": it does not match the naming pattern "{1}".' -f $name, $NamingPattern)
    }

    $alias = if ($SiteAlias) { $SiteAlias } else { ($name -replace '[^\\w]', '') }

    $existing = Get-MgGroup -Filter ("mailNickname eq '{0}'" -f $alias) -ErrorAction SilentlyContinue |
                Select-Object -First 1
    if ($existing) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $alias `
            -Message 'Skipped - a group with this alias already exists (idempotent)'
        continue
    }

    $results.Add([PSCustomObject]@{
        Name        = $name
        Id          = $alias
        SiteName    = $name
        SiteAlias   = $alias
        Template    = $Template
        Owner       = $ownerUser.UserPrincipalName
        OwnerId     = $ownerUser.Id
        Description = $Description
        Ticket      = $TicketReference
        Creates     = if ($Template -eq 'Team') { 'M365 group + mailbox + Planner + Teams entitlement + site' }
                      else { 'Site only, no group' }
    })
}
""",
    act="""
if ($item.Template -eq 'Team') {
    # A group-connected team site is created by creating the group; SharePoint
    # provisions the site behind it.
    $body = @{
        displayName     = $item.SiteName
        mailNickname    = $item.SiteAlias
        description     = $item.Description
        groupTypes      = @('Unified')
        mailEnabled     = $true
        securityEnabled = $false
        visibility      = 'Private'
        'owners@odata.bind' = @(('https://graph.microsoft.com/v1.0/users/{0}' -f $item.OwnerId))
    }
    New-MgGroup -BodyParameter $body -ErrorAction Stop | Out-Null
    $detail = 'group-connected team site (group provisioning may take a few minutes)'
} else {
    throw 'Communication site creation is not exposed through the Graph v1.0 sites API. ' +
          'Create it with PnP.PowerShell (New-PnPSite -Type CommunicationSite) or the admin centre, ' +
          'then re-run reporting scripts against it.'
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Site provisioning requested: {0}. Owner {1}. Ticket={2}' -f $detail, $item.Owner, $item.Ticket)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'SiteProvisioned'; Detail = $detail; Succeeded = $true })
"""),

4: dict(
    file='Get-SharePointStorageReport',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Sites'],
    synopsis='Reports SharePoint site storage usage against quota.',
    desc='Lists sites with their storage consumption and remaining headroom, flagging any above the '
         'threshold. Headroom matters more than raw size: a 900GB site on a 1TB quota is a problem '
         'and a 900GB site on a 5TB quota is not.',
    params=[dict(name='WarnAtPercent', help='Flag a site using at least this much of its quota.',
                 decl="[ValidateRange(1,100)]\n    [int]$WarnAtPercent = 80"),
            dict(name='MinimumSizeGB', help='Ignore sites smaller than this, to keep the report focused.',
                 decl="[double]$MinimumSizeGB = 1")],
    perms='Microsoft Graph Sites.Read.All and Reports.Read.All.',
    notes='Storage figures come from the SharePoint usage report, which lags actual usage by 1-2 '
          'days. A site that grew sharply yesterday may not show it yet.',
    examples=[("-WarnAtPercent 80 -OutputFormat HTML", 'Storage report as HTML.'),
              ("-MinimumSizeGB 10 -OutputFormat CSV", 'Only sites over 10GB.')],
    discover=graph("Sites.Read.All','Reports.Read.All") + """
# The usage report is a CSV download rather than a JSON collection.
$tmp = [System.IO.Path]::GetTempFileName()
try {
    Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/reports/getSharePointSiteUsageDetail(period='D7')" `
        -OutputFilePath $tmp -ErrorAction Stop

    $rows = Import-Csv -LiteralPath $tmp
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

foreach ($row in $rows) {
    $usedBytes = [double]($row.'Storage Used (Byte)')
    $quotaBytes = [double]($row.'Storage Allocated (Byte)')
    $usedGB = [math]::Round($usedBytes / 1GB, 2)

    if ($usedGB -lt $MinimumSizeGB) { continue }

    $pct = if ($quotaBytes -gt 0) { [math]::Round(($usedBytes / $quotaBytes) * 100, 1) } else { $null }

    $results.Add([PSCustomObject]@{
        Name          = $row.'Site URL'
        Id            = $row.'Site Id'
        OwnerDisplay  = $row.'Owner Display Name'
        OwnerUpn      = $row.'Owner Principal Name'
        UsedGB        = $usedGB
        QuotaGB       = [math]::Round($quotaBytes / 1GB, 2)
        PercentUsed   = $pct
        FileCount     = $row.'File Count'
        ActiveFileCount = $row.'Active File Count'
        LastActivity  = $row.'Last Activity Date'
        Template      = $row.'Root Web Template'
        Status        = if ($null -ne $pct -and $pct -ge $WarnAtPercent) { 'Warning' } else { 'OK' }
    })
    if ($null -ne $pct -and $pct -ge $WarnAtPercent) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $row.'Site URL' `
            -Message ('Storage {0}% of quota ({1}GB of {2}GB)' -f $pct, $usedGB, [math]::Round($quotaBytes/1GB,2))
    }
}
"""),

5: dict(
    file='Get-OneDriveExternalSharing',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Files'],
    synopsis='Audits OneDrive items shared with people outside the organisation.',
    desc='Finds OneDrive items carrying sharing links that reach external recipients, or anonymous '
         '"anyone" links. An anonymous link is the higher finding: it needs no sign-in, so it works '
         'for anybody who obtains the URL, including after the recipient has left.',
    params=[dict(name='UserPrincipalName', help='Limit to specific users. All licensed users when omitted.',
                 decl="[string[]]$UserPrincipalName"),
            dict(name='MaxUsers', help='Maximum users to scan when -UserPrincipalName is omitted.',
                 decl="[ValidateRange(1,10000)]\n    [int]$MaxUsers = 200"),
            dict(name='MaxItemsPerUser', help='Maximum items to examine per drive.',
                 decl="[ValidateRange(1,5000)]\n    [int]$MaxItemsPerUser = 500")],
    perms='Microsoft Graph Files.Read.All, Sites.Read.All and User.Read.All.',
    notes='Scanning every drive is slow and rate-limited. Use -UserPrincipalName for a targeted '
          'audit, and treat the tenant-wide scan as a scheduled overnight job rather than an '
          'interactive one.',
    examples=[("-UserPrincipalName user@contoso.com", 'Audits one user\\u2019s OneDrive.'),
              ("-MaxUsers 50 -OutputFormat HTML", 'Samples 50 users and writes an HTML report.')],
    discover=graph("Files.Read.All','Sites.Read.All','User.Read.All") + """
$tenantDomains = @()
try {
    $orgResp = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization' -ErrorAction Stop
    $tenantDomains = @($orgResp.value[0].verifiedDomains.name)
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message 'Could not read verified domains; external detection may be inaccurate'
}

$users = if ($UserPrincipalName) { $UserPrincipalName | ForEach-Object { Get-MgUser -UserId $_ -ErrorAction Stop } }
         else { Get-MgUser -Filter 'assignedLicenses/$count ne 0' -ConsistencyLevel eventual -CountVariable c -Top $MaxUsers -ErrorAction Stop }

foreach ($u in $users) {
    $drive = $null
    try { $drive = Get-MgUserDrive -UserId $u.Id -ErrorAction Stop } catch {
        Write-Verbose ('No OneDrive for {0}' -f $u.UserPrincipalName)
        continue
    }

    $items = @()
    try {
        $items = Get-MgDriveItem -DriveId $drive.Id -Filter 'shared ne null' -Top $MaxItemsPerUser -ErrorAction Stop
    } catch {
        # Fall back to enumerating the root children where the filter is unsupported.
        try { $items = Get-MgDriveRootChild -DriveId $drive.Id -Top $MaxItemsPerUser -ErrorAction Stop } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $u.UserPrincipalName `
                -Message ('Drive enumeration failed: {0}' -f $_.Exception.Message)
            continue
        }
    }

    foreach ($it in $items) {
        if (-not $it.Shared) { continue }

        $perms = @()
        try { $perms = @(Get-MgDriveItemPermission -DriveId $drive.Id -DriveItemId $it.Id -ErrorAction Stop) } catch {
            Write-Verbose ('Permissions unreadable for {0}' -f $it.Name)
            continue
        }

        foreach ($p in $perms) {
            $scope = $p.Link.Scope
            $isAnonymous = ($scope -eq 'anonymous')

            $externalRecipients = @()
            foreach ($identity in @($p.GrantedToIdentitiesV2) + @($p.GrantedToV2)) {
                $addr = $identity.User.AdditionalProperties.email
                if (-not $addr) { $addr = $identity.User.UserPrincipalName }
                if (-not $addr) { continue }
                $domain = ($addr -split '@')[-1]
                if ($tenantDomains -notcontains $domain) { $externalRecipients += $addr }
            }

            if (-not $isAnonymous -and $externalRecipients.Count -eq 0) { continue }

            $results.Add([PSCustomObject]@{
                Name          = ('{0} / {1}' -f $u.UserPrincipalName, $it.Name)
                Id            = $it.Id
                Owner         = $u.UserPrincipalName
                ItemName      = $it.Name
                ItemType      = if ($it.Folder) { 'Folder' } else { 'File' }
                SizeMB        = if ($it.Size) { [math]::Round($it.Size / 1MB, 2) } else { $null }
                WebUrl        = $it.WebUrl
                LinkScope     = $scope
                LinkType      = $p.Link.Type
                IsAnonymous   = $isAnonymous
                ExternalRecipients = ($externalRecipients -join '; ')
                ExpiresOn     = $p.ExpirationDateTime
                Severity      = if ($isAnonymous) { 'HIGH - anonymous link works for anyone with the URL' }
                                else { 'Medium - shared with named external recipients' }
            })
            if ($isAnonymous) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $it.Name `
                    -Message ('Anonymous sharing link on {0} owned by {1}' -f $it.Name, $u.UserPrincipalName)
            }
        }
    }
}
"""),

6: dict(
    file='Get-IntuneDeviceCompliance',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.DeviceManagement'],
    synopsis='Reports Intune device compliance state with owner detail.',
    desc='Lists managed devices with their compliance state, last sync and enrolled owner. Devices '
         'that have not checked in for a long time are reported separately from non-compliant ones, '
         'because a stale device is not the same problem as a failing one.',
    params=[dict(name='OnlyNonCompliant', help='Report only devices that are not compliant.',
                 decl="[switch]$OnlyNonCompliant"),
            dict(name='StaleSyncDays', help='Flag devices that have not synced for this many days.',
                 decl="[ValidateRange(1,365)]\n    [int]$StaleSyncDays = 14"),
            dict(name='OperatingSystem', help='Limit to specific platforms.',
                 decl="[string[]]$OperatingSystem")],
    perms='Microsoft Graph DeviceManagementManagedDevices.Read.All.',
    examples=[("-OnlyNonCompliant -OutputFormat HTML", 'Non-compliant devices with owners, as HTML.'),
              ("-StaleSyncDays 30 -OperatingSystem Windows", 'Stale Windows devices only.')],
    discover=graph("DeviceManagementManagedDevices.Read.All") + """
$devices = Get-MgDeviceManagementManagedDevice -All -ErrorAction Stop

foreach ($d in $devices) {
    if ($OperatingSystem -and $OperatingSystem -notcontains $d.OperatingSystem) { continue }

    $staleDays = if ($d.LastSyncDateTime) {
                     [math]::Round(((Get-Date) - $d.LastSyncDateTime).TotalDays, 1)
                 } else { $null }

    $issues = @()
    if ($d.ComplianceState -ne 'compliant') { $issues += ('compliance: {0}' -f $d.ComplianceState) }
    if ($null -eq $staleDays)               { $issues += 'never synced' }
    elseif ($staleDays -gt $StaleSyncDays)  { $issues += ('last sync {0}d ago' -f $staleDays) }
    if ($d.IsEncrypted -eq $false)          { $issues += 'not encrypted' }
    if ($d.JailBroken -eq 'True')           { $issues += 'JAILBROKEN' }

    if ($OnlyNonCompliant -and $issues.Count -eq 0) { continue }

    $results.Add([PSCustomObject]@{
        Name            = $d.DeviceName
        Id              = $d.Id
        UserPrincipalName = $d.UserPrincipalName
        UserDisplayName = $d.UserDisplayName
        OperatingSystem = $d.OperatingSystem
        OsVersion       = $d.OsVersion
        Model           = $d.Model
        Manufacturer    = $d.Manufacturer
        SerialNumber    = $d.SerialNumber
        ComplianceState = "$($d.ComplianceState)"
        OwnerType       = "$($d.ManagedDeviceOwnerType)"
        EnrolledOn      = $d.EnrolledDateTime
        LastSync        = $d.LastSyncDateTime
        StaleDays       = $staleDays
        IsEncrypted     = $d.IsEncrypted
        JailBroken      = $d.JailBroken
        Status          = if ($issues.Count) { 'NonCompliant' } else { 'Compliant' }
        Issues          = ($issues -join '; ')
    })
}
"""),

7: dict(
    file='Add-IntuneAppAssignment',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Devices.CorporateManagement'],
    synopsis='Assigns an Intune application to a device or user group.',
    desc='Targets an app at a group with a required or available intent. Both the app and the '
         'target group are reported before approval, because assigning the wrong app to All Devices '
         'is a tenant-wide event that is awkward to undo quietly.',
    params=[dict(name='AppName', help='Display name of the Intune application.',
                 decl="[Parameter(Mandatory)]\n    [string]$AppName"),
            dict(name='GroupName', help='Target group display name.',
                 decl="[Parameter(Mandatory)]\n    [string]$GroupName"),
            dict(name='Intent', help='Required installs it; Available offers it in Company Portal; Uninstall removes it.',
                 decl="[ValidateSet('Required','Available','Uninstall')]\n    [string]$Intent = 'Available'"),
            dict(name='AllowAllDevicesTarget', help='Permit targeting the built-in All Devices or All Users groups. Off by default.',
                 decl="[switch]$AllowAllDevicesTarget")],
    perms='Microsoft Graph DeviceManagementApps.ReadWrite.All and Group.Read.All.',
    actionVerb='Assign Intune app',
    reason='Intune application assignment',
    rollback='Remove the assignment. A Required assignment that has already installed the app does '
             'not uninstall it on removal - use -Intent Uninstall for that.',
    notes='Required intent installs silently on every device in the target group at next check-in. '
          'Available only offers it in Company Portal. Choosing Required against a large group is '
          'the difference between an offer and a fleet-wide deployment.',
    examples=[("-AppName 'Company VPN' -GroupName 'GG-Laptops' -Intent Required",
               'REQUEST mode - raises an approval showing app and target.'),
              ("-AppName 'Company VPN' -GroupName 'GG-Laptops' -Intent Available -ApprovalReference APR-...",
               'Applies the approved assignment.')],
    discover=graph("DeviceManagementApps.ReadWrite.All','Group.Read.All") + """
$app = Get-MgDeviceAppManagementMobileApp -Filter ("displayName eq '{0}'" -f ($AppName -replace "'", "''")) `
        -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $app) { throw ('Intune application "{0}" not found.' -f $AppName) }

$group = Get-MgGroup -Filter ("displayName eq '{0}'" -f ($GroupName -replace "'", "''")) `
         -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $group) { throw ('Group "{0}" not found.' -f $GroupName) }

# Broad built-in targets deserve a deliberate decision.
if (-not $AllowAllDevicesTarget -and $GroupName -match '(?i)^All (Devices|Users)$') {
    throw ('Refusing to target "{0}" without -AllowAllDevicesTarget. That is a tenant-wide assignment.' -f $GroupName)
}

$memberCount = 0
try { $memberCount = @(Get-MgGroupMember -GroupId $group.Id -All -ErrorAction Stop).Count } catch {
    Write-Verbose ('Could not count members of {0}' -f $GroupName)
}

$existing = @(Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $app.Id -ErrorAction SilentlyContinue)
if ($existing | Where-Object { $_.Target.AdditionalProperties.groupId -eq $group.Id -and "$($_.Intent)" -eq $Intent }) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $AppName `
        -Message 'Skipped - assignment already exists with this intent (idempotent)'
    return
}

$results.Add([PSCustomObject]@{
    Name        = ('{0} -> {1}' -f $app.DisplayName, $group.DisplayName)
    Id          = $app.Id
    AppName     = $app.DisplayName
    AppId       = $app.Id
    AppType     = ($app.AdditionalProperties.'@odata.type' -replace '#microsoft.graph.', '')
    Publisher   = $app.Publisher
    GroupName   = $group.DisplayName
    GroupId     = $group.Id
    GroupMembers= $memberCount
    Intent      = $Intent
    Impact      = if ($Intent -eq 'Required') { ('Installs silently on {0} member(s) at next check-in' -f $memberCount) }
                  elseif ($Intent -eq 'Uninstall') { ('Removes the app from {0} member(s)' -f $memberCount) }
                  else { ('Offered in Company Portal to {0} member(s)' -f $memberCount) }
})
""",
    act="""
$body = @{
    mobileAppAssignments = @(@{
        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
        intent = $item.Intent.ToLower()
        target = @{
            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
            groupId = $item.GroupId
        }
    })
}

Invoke-MgGraphRequest -Method POST `
    -Uri ('https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/{0}/assign' -f $item.AppId) `
    -Body ($body | ConvertTo-Json -Depth 8) -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'App assigned with intent {0}. {1}. Approval={2}' -f $item.Intent, $item.Impact, $ApprovalReference)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'AppAssigned'; Detail = $item.Impact; Succeeded = $true })
"""),

8: dict(
    file='Clear-IntuneManagedDevice',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.DeviceManagement.Actions'],
    synopsis='Retires or wipes an Intune-managed device.',
    desc='Removes company data from a device (retire) or resets it to factory state (wipe). A wipe '
         'destroys the user\'s personal data on a BYOD device and cannot be undone, so it requires '
         'approval, a verified ITSM trigger, and an explicit -Execute. Retire is the default '
         'because it removes company data without touching anything else.',
    params=[dict(name='DeviceName', help='Device name(s) to act on.',
                 decl="[string[]]$DeviceName"),
            dict(name='DeviceId', help='Specific Intune device id(s).',
                 decl="[string[]]$DeviceId"),
            dict(name='Action', help='Retire removes company data only; Wipe resets the device to factory state.',
                 decl="[ValidateSet('Retire','Wipe')]\n    [string]$Action = 'Retire'"),
            dict(name='KeepEnrollmentData', help='On a wipe, retain the enrolment state so the device re-enrols automatically.',
                 decl="[switch]$KeepEnrollmentData"),
            dict(name='ItsmTriggerVerified', help='Confirms the request came from a verified ITSM trigger. Required for Wipe.',
                 decl="[switch]$ItsmTriggerVerified")],
    minage=0,
    perms='Microsoft Graph DeviceManagementManagedDevices.PrivilegedOperations.All.',
    actionVerb='Retire or wipe device',
    reason='Device retire or wipe (ITSM-verified)',
    rollback='NONE. A retire can be followed by re-enrolment, but a WIPE destroys all data on the '
             'device including the user\\u2019s personal content on a BYOD handset. There is no undo.',
    notes='On a personally-owned device, Retire is almost always the correct action: it removes '
          'company apps and data and leaves the user\\u2019s photos, messages and accounts intact. '
          'Wipe is for corporate-owned devices, and for lost handsets where the data must not '
          'survive under any circumstances.',
    examples=[("-DeviceName LAPTOP-01",
               'REPORT ONLY. Shows the device and raises an approval for a retire.'),
              ("-DeviceName LAPTOP-01 -Action Wipe -ItsmTriggerVerified -ApprovalReference APR-... -Execute",
               'Wipes the approved device.')],
    discover=graph("DeviceManagementManagedDevices.Read.All','DeviceManagementManagedDevices.PrivilegedOperations.All") + """
if ($Action -eq 'Wipe' -and -not $ItsmTriggerVerified) {
    throw 'Refusing to wipe without -ItsmTriggerVerified. A wipe destroys all data on the device, ' +
          'including personal content on a BYOD handset, and cannot be undone.'
}
if (-not $DeviceName -and -not $DeviceId) {
    throw 'Specify -DeviceName or -DeviceId. Acting on every managed device is not a safe default.'
}

$devices = @()
foreach ($n in $DeviceName) {
    $devices += Get-MgDeviceManagementManagedDevice -Filter ("deviceName eq '{0}'" -f ($n -replace "'", "''")) -ErrorAction Stop
}
foreach ($i in $DeviceId) {
    $devices += Get-MgDeviceManagementManagedDevice -ManagedDeviceId $i -ErrorAction Stop
}

foreach ($d in $devices) {
    $isPersonal = ("$($d.ManagedDeviceOwnerType)" -eq 'personal')

    if ($Action -eq 'Wipe' -and $isPersonal) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $d.DeviceName -Message (
            'This is a PERSONALLY-OWNED device. A wipe destroys the user''s own data. ' +
            'Retire removes company data only and is usually the correct action.')
    }

    $results.Add([PSCustomObject]@{
        Name            = $d.DeviceName
        Id              = $d.Id
        UserPrincipalName = $d.UserPrincipalName
        OperatingSystem = $d.OperatingSystem
        Model           = $d.Model
        SerialNumber    = $d.SerialNumber
        OwnerType       = "$($d.ManagedDeviceOwnerType)"
        IsPersonal      = $isPersonal
        ComplianceState = "$($d.ComplianceState)"
        LastSync        = $d.LastSyncDateTime
        Action          = $Action
        Impact          = if ($Action -eq 'Wipe' -and $isPersonal) { 'FACTORY RESET of a personally-owned device - destroys personal data' }
                          elseif ($Action -eq 'Wipe') { 'FACTORY RESET - all data destroyed' }
                          else { 'Company data and apps removed; personal data untouched' }
    })
}
""",
    act="""
Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
    '{0} requested. {1}. Approval={2} Ticket={3} ItsmVerified={4}' -f
    $item.Action.ToUpper(), $item.Impact, $ApprovalReference, $TicketReference, $true)

if ($item.Action -eq 'Wipe') {
    $body = @{
        keepEnrollmentData = [bool]$KeepEnrollmentData
        keepUserData       = $false
    }
    Invoke-MgGraphRequest -Method POST `
        -Uri ('https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/{0}/wipe' -f $item.Id) `
        -Body ($body | ConvertTo-Json) -ErrorAction Stop | Out-Null
    $detail = 'wipe issued - factory reset'
} else {
    Invoke-MgGraphRequest -Method POST `
        -Uri ('https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/{0}/retire' -f $item.Id) `
        -ErrorAction Stop | Out-Null
    $detail = 'retire issued - company data removed'
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0}. The device applies it at its next check-in.' -f $detail)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Action; Detail = $detail; Succeeded = $true })
"""),

9: dict(
    file='Get-M365LicenseOptimization',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Users'],
    synopsis='Reports unassigned and under-used Microsoft 365 licences.',
    desc='Cross-references purchased licence counts against assignments and sign-in activity, '
         'identifying unassigned seats and licences held by dormant accounts. Both cost money; the '
         'second is also a security finding, since a dormant licensed account is a live target.',
    params=[dict(name='DormantDays', help='Treat an account with no sign-in for this long as dormant.',
                 decl="[ValidateRange(1,3650)]\n    [int]$DormantDays = 60"),
            dict(name='EstimatedCostPerSeat', help='Optional monthly cost per seat, used to quantify the finding.',
                 decl="[hashtable]$EstimatedCostPerSeat = @{}")],
    perms='Microsoft Graph Organization.Read.All, User.Read.All and AuditLog.Read.All.',
    notes='Sign-in activity needs Entra ID P1 or above. Without it, lastSignInDateTime is null for '
          'every user and no account can be classified as dormant - the script reports that '
          'explicitly rather than reporting everyone as dormant.',
    examples=[("-DormantDays 90 -OutputFormat HTML", 'Optimisation report as HTML.'),
              ("-EstimatedCostPerSeat @{ENTERPRISEPACK=23}", 'Quantifies waste for one SKU.')],
    discover=graph("Organization.Read.All','User.Read.All','AuditLog.Read.All") + """
$skus = Get-MgSubscribedSku -All -ErrorAction Stop
$cutoff = (Get-Date).AddDays(-$DormantDays)
$noActivityData = 0

# --- unassigned seats -----------------------------------------------------
foreach ($sku in $skus) {
    $unassigned = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
    if ($unassigned -le 0) { continue }

    $cost = if ($EstimatedCostPerSeat.ContainsKey($sku.SkuPartNumber)) {
                [double]$EstimatedCostPerSeat[$sku.SkuPartNumber] } else { $null }

    $results.Add([PSCustomObject]@{
        Name        = $sku.SkuPartNumber
        Id          = $sku.SkuId
        Finding     = 'Unassigned seats'
        SkuPartNumber = $sku.SkuPartNumber
        Purchased   = $sku.PrepaidUnits.Enabled
        Assigned    = $sku.ConsumedUnits
        Unassigned  = $unassigned
        UserPrincipalName = $null
        LastSignIn  = $null
        EstMonthlyWaste = if ($null -ne $cost) { [math]::Round($unassigned * $cost, 2) } else { $null }
        Recommendation = 'Reduce the subscription count, or assign the spare seats'
    })
}

# --- licences on dormant accounts ----------------------------------------
$users = Get-MgUser -Filter 'assignedLicenses/$count ne 0' -ConsistencyLevel eventual -CountVariable c -All `
    -Property Id,UserPrincipalName,DisplayName,AssignedLicenses,SignInActivity,AccountEnabled -ErrorAction Stop

foreach ($u in $users) {
    $lastSignIn = $u.SignInActivity.LastSignInDateTime
    if (-not $lastSignIn) { $noActivityData++; continue }   # unknown is not dormant
    if ($lastSignIn -ge $cutoff) { continue }

    foreach ($lic in $u.AssignedLicenses) {
        $sku = $skus | Where-Object SkuId -eq $lic.SkuId | Select-Object -First 1
        if (-not $sku) { continue }
        $cost = if ($EstimatedCostPerSeat.ContainsKey($sku.SkuPartNumber)) {
                    [double]$EstimatedCostPerSeat[$sku.SkuPartNumber] } else { $null }

        $results.Add([PSCustomObject]@{
            Name        = $u.UserPrincipalName
            Id          = $u.Id
            Finding     = 'Licence on a dormant account'
            SkuPartNumber = $sku.SkuPartNumber
            Purchased   = $null
            Assigned    = $null
            Unassigned  = $null
            UserPrincipalName = $u.UserPrincipalName
            AccountEnabled = $u.AccountEnabled
            LastSignIn  = $lastSignIn
            DormantDays = [math]::Round(((Get-Date) - $lastSignIn).TotalDays, 0)
            EstMonthlyWaste = $cost
            Recommendation = 'Confirm the account is still needed; if it is a leaver, offboard and reclaim the licence'
        })
    }
}

if ($noActivityData -gt 0) {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        '{0} licensed user(s) have no sign-in activity data and were NOT classified as dormant. ' +
        'This usually means the tenant lacks Entra ID P1.' -f $noActivityData)
}
"""),

10: dict(
    file='Get-EntraConditionalAccessAudit',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.SignIns'],
    synopsis='Exports and audits Entra ID Conditional Access policies.',
    desc='Exports every Conditional Access policy with its conditions, grant controls and state, '
         'flagging the configurations worth questioning: policies left in report-only, policies '
         'with no MFA requirement, and excluded users who quietly bypass the control.',
    params=[dict(name='IncludeDisabled', help='Include policies that are disabled.',
                 decl="[switch]$IncludeDisabled")],
    perms='Microsoft Graph Policy.Read.All.',
    notes='An exclusion list is the usual place a Conditional Access policy is undermined. Break-glass '
          'accounts belong there deliberately; anything else in the list should be justified, so '
          'exclusions are reported explicitly rather than summarised away.',
    examples=[("-OutputFormat HTML", 'Full CA policy export as HTML.'),
              ("-IncludeDisabled -OutputFormat JSON", 'Everything including disabled policies.')],
    discover=graph("Policy.Read.All") + """
$policies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop

foreach ($p in $policies) {
    if (-not $IncludeDisabled -and "$($p.State)" -eq 'disabled') { continue }

    $grants = @($p.GrantControls.BuiltInControls)
    $excludedUsers = @($p.Conditions.Users.ExcludeUsers)
    $excludedGroups = @($p.Conditions.Users.ExcludeGroups)
    $excludedRoles = @($p.Conditions.Users.ExcludeRoles)

    $issues = @()
    if ("$($p.State)" -eq 'enabledForReportingButNotEnforced') { $issues += 'REPORT-ONLY - not enforcing' }
    if ($grants -notcontains 'mfa' -and $grants -notcontains 'compliantDevice' -and
        $grants -notcontains 'domainJoinedDevice') { $issues += 'no MFA or device requirement' }
    if (($excludedUsers.Count + $excludedGroups.Count + $excludedRoles.Count) -gt 0) {
        $issues += ('{0} exclusion(s) bypass this policy' -f ($excludedUsers.Count + $excludedGroups.Count + $excludedRoles.Count))
    }
    if ($p.Conditions.Users.IncludeUsers -contains 'All' -and $excludedUsers.Count -eq 0 -and
        $excludedGroups.Count -eq 0) {
        $issues += 'applies to All users with no break-glass exclusion'
    }

    $results.Add([PSCustomObject]@{
        Name            = $p.DisplayName
        Id              = $p.Id
        State           = "$($p.State)"
        CreatedAt       = $p.CreatedDateTime
        ModifiedAt      = $p.ModifiedDateTime
        IncludeUsers    = (($p.Conditions.Users.IncludeUsers) -join '; ')
        ExcludeUsers    = ($excludedUsers -join '; ')
        ExcludeGroups   = ($excludedGroups -join '; ')
        ExcludeRoles    = ($excludedRoles -join '; ')
        IncludeApps     = (($p.Conditions.Applications.IncludeApplications) -join '; ')
        ClientAppTypes  = (($p.Conditions.ClientAppTypes) -join '; ')
        Platforms       = (($p.Conditions.Platforms.IncludePlatforms) -join '; ')
        Locations       = (($p.Conditions.Locations.IncludeLocations) -join '; ')
        GrantControls   = ($grants -join '; ')
        GrantOperator   = "$($p.GrantControls.Operator)"
        SessionControls = if ($p.SessionControls) { 'configured' } else { 'none' }
        Status          = if ($issues.Count) { 'Review' } else { 'OK' }
        Issues          = ($issues -join '; ')
    })
    if ($issues.Count) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $p.DisplayName -Message ($issues -join '; ')
    }
}
"""),

11: dict(
    file='Get-EntraPimActivationReport',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.Governance'],
    synopsis='Reports Privileged Identity Management role activations.',
    desc='Lists PIM role activations over the lookback window with the activating user, role, '
         'justification and duration. Activations outside working hours and activations without a '
         'justification are flagged, since both are worth a second look in a privileged-access review.',
    params=[dict(name='LookbackDays', help='How far back to report.',
                 decl="[ValidateRange(1,90)]\n    [int]$LookbackDays = 1"),
            dict(name='OutOfHoursStart', help='Hour after which an activation is considered out of hours.',
                 decl="[ValidateRange(0,23)]\n    [int]$OutOfHoursStart = 19"),
            dict(name='OutOfHoursEnd', help='Hour before which an activation is considered out of hours.',
                 decl="[ValidateRange(0,23)]\n    [int]$OutOfHoursEnd = 7")],
    perms='Microsoft Graph RoleAssignmentSchedule.Read.Directory and RoleManagement.Read.Directory. Requires Entra ID P2.',
    notes='PIM requires an Entra ID P2 licence. Without it these endpoints return nothing, which '
          'the script reports as an absence of PIM rather than as an absence of activations.',
    examples=[("-LookbackDays 1", 'Daily privileged activation report.'),
              ("-LookbackDays 7 -OutputFormat HTML", 'Weekly report as HTML.')],
    discover=graph("RoleAssignmentSchedule.Read.Directory','RoleManagement.Read.Directory','Directory.Read.All") + """
$since = (Get-Date).AddDays(-$LookbackDays)

$requests = @()
try {
    $requests = @(Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -All -ErrorAction Stop |
                  Where-Object { $_.CreatedDateTime -ge $since })
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'PIM data unavailable: {0}. This usually means the tenant lacks Entra ID P2.' -f $_.Exception.Message)
    return
}

if ($requests.Count -eq 0) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
        'No PIM activations in the last {0} day(s).' -f $LookbackDays)
}

$roleCache = @{}

foreach ($r in $requests) {
    if ("$($r.Action)" -notmatch 'selfActivate|adminAssign') { continue }

    if (-not $roleCache.ContainsKey($r.RoleDefinitionId)) {
        try {
            $roleCache[$r.RoleDefinitionId] = (Get-MgRoleManagementDirectoryRoleDefinition `
                -UnifiedRoleDefinitionId $r.RoleDefinitionId -ErrorAction Stop).DisplayName
        } catch { $roleCache[$r.RoleDefinitionId] = $r.RoleDefinitionId }
    }

    $principal = $r.PrincipalId
    try {
        $u = Get-MgUser -UserId $r.PrincipalId -Property UserPrincipalName,DisplayName -ErrorAction Stop
        $principal = $u.UserPrincipalName
    } catch {
        Write-Verbose ('Could not resolve principal {0}' -f $r.PrincipalId)
    }

    $hour = $r.CreatedDateTime.Hour
    $outOfHours = if ($OutOfHoursStart -gt $OutOfHoursEnd) { ($hour -ge $OutOfHoursStart) -or ($hour -lt $OutOfHoursEnd) }
                  else { ($hour -ge $OutOfHoursStart) -and ($hour -lt $OutOfHoursEnd) }

    $flags = @()
    if ($outOfHours) { $flags += 'activated out of hours' }
    if (-not $r.Justification) { $flags += 'no justification given' }
    if ("$($r.Action)" -eq 'adminAssign') { $flags += 'admin-assigned rather than self-activated' }

    $results.Add([PSCustomObject]@{
        Name          = ('{0} : {1}' -f $principal, $roleCache[$r.RoleDefinitionId])
        Id            = $r.Id
        Principal     = $principal
        RoleName      = $roleCache[$r.RoleDefinitionId]
        Action        = "$($r.Action)"
        Status        = "$($r.Status)"
        ActivatedAt   = $r.CreatedDateTime
        StartDateTime = $r.ScheduleInfo.StartDateTime
        Expiration    = $r.ScheduleInfo.Expiration.EndDateTime
        DurationHours = if ($r.ScheduleInfo.Expiration.Duration) { "$($r.ScheduleInfo.Expiration.Duration)" } else { $null }
        Justification = $r.Justification
        OutOfHours    = $outOfHours
        Flags         = ($flags -join '; ')
    })
    if ($flags.Count) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $principal -Message (
            '{0} activation: {1}' -f $roleCache[$r.RoleDefinitionId], ($flags -join '; '))
    }
}
"""),
}

# Use cases 12-22 live in their own module to keep this file readable.
try:
    from spec_m365b import EXTRA as _EXTRA
    SPECS.update(_EXTRA)
except ImportError:
    pass
