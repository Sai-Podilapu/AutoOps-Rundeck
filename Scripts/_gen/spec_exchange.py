# -*- coding: utf-8 -*-
"""Exchange & O365 - use cases 1-14. Real ExchangeOnlineManagement cmdlets."""

MBX = dict(name='Mailbox', help='Target mailbox (UPN or primary SMTP address).',
           decl="[Parameter(Mandatory)]\n    [string[]]$Mailbox")
TRUSTEE = dict(name='Trustee', help='User being granted or removed (UPN or primary SMTP address).',
               decl="[Parameter(Mandatory)]\n    [string[]]$Trustee")

# Every Exchange script connects app-only. Interactive auth is unusable for
# automation and a stored username/password would violate the credential rule.
CONNECT = """
$exoParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
if ($config -and $config.azure) {
    if ($config.azure.applicationId)         { $exoParams.AppId = $config.azure.applicationId }
    if ($config.azure.certificateThumbprint) { $exoParams.CertificateThumbprint = $config.azure.certificateThumbprint }
    if ($config.azure.tenantId)              { $exoParams.Organization = $config.azure.tenantId }
}
if (-not $exoParams.AppId) {
    throw 'Exchange Online requires app-only certificate auth. Set azure.applicationId, ' +
          'azure.certificateThumbprint and azure.tenantId in config.json.'
}
Connect-ExchangeOnline @exoParams
Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Exchange Online (app-only certificate auth)'
"""

SPECS = {

1: dict(
    file='Get-ExoHealthReport',
    modules=['ExchangeOnlineManagement'],
    synopsis='Reports Exchange Online mailbox health, quota usage and configuration risks.',
    desc='Collects mailbox statistics, quota headroom, litigation hold state, archive status and '
         'forwarding configuration. Quota is reported as headroom rather than raw size, because '
         'a 90GB mailbox is fine on a 100GB quota and a problem on a 50GB one.',
    params=[dict(name='MailboxFilter', help='Limit to mailboxes matching this identity filter.',
                 decl="[string[]]$MailboxFilter"),
            dict(name='QuotaWarnPercent', help='Flag a mailbox using at least this much of its quota.',
                 decl="[ValidateRange(1,100)]\n    [int]$QuotaWarnPercent = 85"),
            dict(name='ResultSize', help='Maximum mailboxes to examine.',
                 decl="[int]$ResultSize = 1000")],
    perms='Exchange Online View-Only Recipients role.',
    examples=[("-OutputFormat HTML", 'Health report across the tenant.'),
              ("-MailboxFilter user@contoso.com -OutputFormat JSON", 'One mailbox in detail.')],
    discover=CONNECT + """
$mailboxes = if ($MailboxFilter) { $MailboxFilter | ForEach-Object { Get-Mailbox -Identity $_ -ErrorAction Stop } }
             else                { Get-Mailbox -ResultSize $ResultSize }

foreach ($mb in $mailboxes) {
    $stats = $null
    try { $stats = Get-MailboxStatistics -Identity $mb.Identity -ErrorAction Stop } catch {
        Write-Verbose ('No statistics for {0}' -f $mb.PrimarySmtpAddress)
    }

    # Quota strings look like "49.5 GB (53,150,220,288 bytes)"; the byte count
    # is the only part worth parsing.
    $quotaBytes = $null
    if ($mb.ProhibitSendReceiveQuota -and "$($mb.ProhibitSendReceiveQuota)" -match '\\(([\\d,]+) bytes\\)') {
        $quotaBytes = [double]($Matches[1] -replace ',', '')
    }
    $usedBytes = $null
    if ($stats -and "$($stats.TotalItemSize)" -match '\\(([\\d,]+) bytes\\)') {
        $usedBytes = [double]($Matches[1] -replace ',', '')
    }
    $pctUsed = if ($quotaBytes -gt 0 -and $null -ne $usedBytes) {
                   [math]::Round(($usedBytes / $quotaBytes) * 100, 1)
               } else { $null }

    $issues = @()
    if ($null -ne $pctUsed -and $pctUsed -ge $QuotaWarnPercent) { $issues += ('quota {0}% used' -f $pctUsed) }
    if ($mb.ForwardingSmtpAddress)   { $issues += ('external forwarding to {0}' -f $mb.ForwardingSmtpAddress) }
    if ($mb.DeliverToMailboxAndForward -eq $false -and $mb.ForwardingAddress) { $issues += 'forwarding without local delivery' }
    if (-not $mb.LitigationHoldEnabled -and $mb.RecipientTypeDetails -eq 'UserMailbox') { $issues += 'no litigation hold' }

    $results.Add([PSCustomObject]@{
        Name              = $mb.PrimarySmtpAddress
        Id                = $mb.Identity
        DisplayName       = $mb.DisplayName
        MailboxType       = "$($mb.RecipientTypeDetails)"
        UsedGB            = if ($null -ne $usedBytes) { [math]::Round($usedBytes / 1GB, 2) } else { $null }
        QuotaGB           = if ($null -ne $quotaBytes) { [math]::Round($quotaBytes / 1GB, 2) } else { $null }
        QuotaPercentUsed  = $pctUsed
        ItemCount         = if ($stats) { $stats.ItemCount } else { $null }
        LastLogon         = if ($stats) { $stats.LastLogonTime } else { $null }
        ArchiveEnabled    = ($mb.ArchiveStatus -eq 'Active')
        LitigationHold    = $mb.LitigationHoldEnabled
        ForwardingSmtp    = $mb.ForwardingSmtpAddress
        HiddenFromGal     = $mb.HiddenFromAddressListsEnabled
        Status            = if ($issues.Count) { 'Warning' } else { 'OK' }
        Issues            = ($issues -join '; ')
    })
}
"""),

2: dict(
    file='Get-O365ServiceHealth',
    modules=['Microsoft.Graph.Authentication'],
    synopsis='Reports current Microsoft 365 service health and active incidents.',
    desc='Pulls the tenant\'s service health overview and any active incidents or advisories from '
         'Microsoft Graph, so a user-reported "Outlook is slow" can be checked against a known '
         'Microsoft-side incident before anyone starts investigating locally.',
    params=[dict(name='IncludeAdvisories', help='Include advisories as well as incidents. Advisories are informational and noisy.',
                 decl="[switch]$IncludeAdvisories"),
            dict(name='ServiceFilter', help='Limit to specific services, e.g. Exchange Online.',
                 decl="[string[]]$ServiceFilter")],
    perms='Microsoft Graph ServiceHealth.Read.All.',
    examples=[("", 'Current service health and active incidents.'),
              ("-ServiceFilter 'Exchange Online' -IncludeAdvisories", 'Exchange only, including advisories.')],
    discover="""
Connect-MgGraph -Scopes 'ServiceHealth.Read.All' -NoWelcome -ErrorAction Stop

$overview = Invoke-MgGraphRequest -Method GET `
    -Uri 'https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/healthOverviews' -ErrorAction Stop

foreach ($svc in $overview.value) {
    if ($ServiceFilter -and $ServiceFilter -notcontains $svc.service) { continue }
    $results.Add([PSCustomObject]@{
        Name        = $svc.service
        Id          = $svc.id
        RecordType  = 'ServiceStatus'
        Status      = $svc.status
        Title       = $null
        Classification = $null
        StartDateTime  = $null
        LastUpdated = $null
        IsResolved  = $null
        Detail      = ('Service status: {0}' -f $svc.status)
    })
}

$issues = Invoke-MgGraphRequest -Method GET `
    -Uri 'https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/issues' -ErrorAction Stop

foreach ($i in $issues.value) {
    if ($ServiceFilter -and $ServiceFilter -notcontains $i.service) { continue }
    if (-not $IncludeAdvisories -and $i.classification -ne 'incident') { continue }
    if ($i.isResolved) { continue }

    $results.Add([PSCustomObject]@{
        Name        = $i.service
        Id          = $i.id
        RecordType  = 'ActiveIssue'
        Status      = $i.status
        Title       = $i.title
        Classification = $i.classification
        StartDateTime  = $i.startDateTime
        LastUpdated = $i.lastModifiedDateTime
        IsResolved  = $i.isResolved
        Detail      = $i.impactDescription
    })
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $i.service -Message (
        'Active {0}: {1} ({2})' -f $i.classification, $i.title, $i.id)
}
"""),

3: dict(
    file='Add-ExoMailboxFullAccess',
    modules=['ExchangeOnlineManagement'],
    synopsis='Grants Full Access permission on a mailbox to another user.',
    desc='Gives a trustee full read access to somebody else\'s mailbox. This is one of the most '
         'privacy-sensitive changes in a tenant, so it is approval-gated and requires a ticket '
         'reference; the workbook makes manager or ITSM approval mandatory.',
    params=[MBX, TRUSTEE,
            dict(name='AutoMapping', help='Auto-map the mailbox into the trustee\\u2019s Outlook. Off by default because it is disruptive and hard to reverse in the client.',
                 decl="[bool]$AutoMapping = $false"),
            dict(name='ExpiryDays', help='Record an intended review date in the audit trail. Exchange does not expire permissions itself.',
                 decl="[ValidateRange(0,3650)]\n    [int]$ExpiryDays = 90")],
    perms='Exchange Online Organization Management, or a custom role with Mailbox Permissions.',
    actionVerb='Grant Full Access',
    reason='Full Access mailbox permission grant',
    rollback='Remove-ExoMailboxFullAccess.ps1, or Remove-MailboxPermission directly. The grant is '
             'immediately reversible, but anything the trustee read in the meantime cannot be unread.',
    notes='Exchange does not support time-limited mailbox permissions. -ExpiryDays records an '
          'intended review date in the audit trail so the grant can be found later; it does NOT '
          'revoke anything automatically.',
    examples=[("-Mailbox shared@contoso.com -Trustee user@contoso.com -TicketReference REQ0012345",
               'REQUEST mode - raises an approval. Grants nothing.'),
              ("-Mailbox shared@contoso.com -Trustee user@contoso.com -TicketReference REQ0012345 -ApprovalReference APR-...",
               'Applies the approved grant.')],
    discover=CONNECT + """
if (-not $TicketReference) {
    throw 'A -TicketReference is required. Full Access grants need manager or ITSM approval per the SOP.'
}

foreach ($mbx in $Mailbox) {
    $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop
    foreach ($tr in $Trustee) {
        $existing = Get-MailboxPermission -Identity $mb.Identity -User $tr -ErrorAction SilentlyContinue |
                    Where-Object { $_.AccessRights -contains 'FullAccess' -and -not $_.IsInherited }
        if ($existing) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0} -> {1}' -f $tr, $mbx) `
                -Message 'Skipped - Full Access already granted (idempotent)'
            continue
        }

        $results.Add([PSCustomObject]@{
            Name          = ('{0} -> {1}' -f $tr, $mb.PrimarySmtpAddress)
            Id            = $mb.Identity
            Mailbox       = $mb.PrimarySmtpAddress
            MailboxType   = "$($mb.RecipientTypeDetails)"
            MailboxOwner  = $mb.DisplayName
            Trustee       = $tr
            AccessRight   = 'FullAccess'
            AutoMapping   = $AutoMapping
            ReviewBy      = if ($ExpiryDays -gt 0) { (Get-Date).AddDays($ExpiryDays) } else { $null }
            Ticket        = $TicketReference
            PrivacyNote   = 'Trustee will be able to read all mail in this mailbox'
        })
    }
}
""",
    act="""
Add-MailboxPermission -Identity $item.Mailbox -User $item.Trustee -AccessRights FullAccess `
    -AutoMapping:$item.AutoMapping -Confirm:$false -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Full Access granted. AutoMapping={0} Ticket={1} Approval={2}. Review by {3}' -f
    $item.AutoMapping, $TicketReference, $ApprovalReference,
    $(if ($item.ReviewBy) { $item.ReviewBy.ToString('yyyy-MM-dd') } else { 'not set' }))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'FullAccessGranted'
    Detail = ('automapping {0}' -f $item.AutoMapping); Succeeded = $true })
"""),

4: dict(
    file='Remove-ExoMailboxFullAccess',
    modules=['ExchangeOnlineManagement'],
    synopsis='Removes Full Access permission from a mailbox.',
    desc='Revokes a trustee\'s full access to a mailbox. Removing access is the low-risk direction, '
         'so it executes directly - but the prior permission set is captured first so it can be '
         'restored if the removal turns out to be wrong.',
    params=[MBX, TRUSTEE,
            dict(name='RemoveAll', help='Remove every non-inherited Full Access grant on the mailbox, not just the named trustee.',
                 decl="[switch]$RemoveAll")],
    perms='Exchange Online Organization Management.',
    actionVerb='Remove Full Access',
    rollback='Re-grant with Add-ExoMailboxFullAccess.ps1. The removed permission is written to the '
             'audit log first, including whether auto-mapping was set.',
    examples=[("-Mailbox shared@contoso.com -Trustee leaver@contoso.com",
               'Removes one trustee\\u2019s access.'),
              ("-Mailbox shared@contoso.com -RemoveAll -WhatIf",
               'Shows every Full Access grant that would be removed.')],
    discover=CONNECT + """
foreach ($mbx in $Mailbox) {
    $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop

    $perms = Get-MailboxPermission -Identity $mb.Identity -ErrorAction Stop |
             Where-Object { $_.AccessRights -contains 'FullAccess' -and -not $_.IsInherited -and
                            $_.User -notlike 'NT AUTHORITY\\\\*' }

    if (-not $RemoveAll) {
        $perms = $perms | Where-Object { $Trustee -contains $_.User.ToString() }
    }

    foreach ($p in $perms) {
        $results.Add([PSCustomObject]@{
            Name        = ('{0} -> {1}' -f $p.User, $mb.PrimarySmtpAddress)
            Id          = $mb.Identity
            Mailbox     = $mb.PrimarySmtpAddress
            Trustee     = "$($p.User)"
            AccessRight = ($p.AccessRights -join ',')
            Deny        = $p.Deny
            Inherited   = $p.IsInherited
        })
    }
}
""",
    act="""
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Prior permission captured: {0} had {1} on {2}' -f $item.Trustee, $item.AccessRight, $item.Mailbox)

Remove-MailboxPermission -Identity $item.Mailbox -User $item.Trustee -AccessRights FullAccess `
    -Confirm:$false -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message 'Full Access removed'
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'FullAccessRemoved'; Detail = $item.AccessRight; Succeeded = $true })
"""),

5: dict(
    file='Get-ExoMailboxPermission',
    modules=['ExchangeOnlineManagement'],
    synopsis='Reports who has permissions on a mailbox.',
    desc='Lists every non-inherited mailbox permission with the trustee and access rights, so an '
         'access review can answer "who can read this mailbox" without opening the admin centre.',
    params=[dict(name='Mailbox', help='Mailboxes to inspect. All mailboxes when omitted.',
                 decl="[string[]]$Mailbox"),
            dict(name='IncludeInherited', help='Include inherited permissions, which are usually noise.',
                 decl="[switch]$IncludeInherited"),
            dict(name='ResultSize', help='Maximum mailboxes to examine when -Mailbox is omitted.',
                 decl="[int]$ResultSize = 500")],
    perms='Exchange Online View-Only Recipients role.',
    examples=[("-Mailbox shared@contoso.com", 'Permissions on one mailbox.'),
              ("-OutputFormat CSV", 'Tenant-wide permission export for an access review.')],
    discover=CONNECT + """
$mailboxes = if ($Mailbox) { $Mailbox | ForEach-Object { Get-Mailbox -Identity $_ -ErrorAction Stop } }
             else          { Get-Mailbox -ResultSize $ResultSize }

foreach ($mb in $mailboxes) {
    $perms = Get-MailboxPermission -Identity $mb.Identity -ErrorAction SilentlyContinue

    foreach ($p in $perms) {
        if (-not $IncludeInherited -and $p.IsInherited) { continue }
        if ("$($p.User)" -like 'NT AUTHORITY\\\\*') { continue }
        if ("$($p.User)" -eq "$($mb.Identity)") { continue }     # self

        $results.Add([PSCustomObject]@{
            Name         = ('{0} -> {1}' -f $p.User, $mb.PrimarySmtpAddress)
            Id           = $mb.Identity
            Mailbox      = $mb.PrimarySmtpAddress
            MailboxType  = "$($mb.RecipientTypeDetails)"
            Trustee      = "$($p.User)"
            AccessRights = ($p.AccessRights -join ',')
            Deny         = $p.Deny
            Inherited    = $p.IsInherited
            IsFullAccess = ($p.AccessRights -contains 'FullAccess')
        })
    }
}
"""),

6: dict(
    file='Add-ExoSendOnBehalf',
    modules=['ExchangeOnlineManagement'],
    synopsis='Grants Send on Behalf Of permission for a mailbox.',
    desc='Allows a trustee to send messages on behalf of a mailbox. Recipients see "Trustee on '
         'behalf of Owner", so the delegation is visible - unlike Send As. Still a delegation grant, '
         'so it is approval-gated.',
    params=[MBX, TRUSTEE],
    perms='Exchange Online Organization Management, or Mail Recipients role.',
    actionVerb='Grant Send on Behalf',
    reason='Send on Behalf delegation grant',
    rollback='Remove-ExoSendOnBehalf.ps1. Immediately reversible.',
    notes='Send on Behalf is visibly attributed to the sender, which makes it the safer choice '
          'where Send As is not strictly required. If someone asks for Send As, check whether Send '
          'on Behalf would meet the need.',
    examples=[("-Mailbox shared@contoso.com -Trustee user@contoso.com -TicketReference REQ0012345",
               'REQUEST mode - raises an approval.'),
              ("-Mailbox shared@contoso.com -Trustee user@contoso.com -ApprovalReference APR-...",
               'Applies the approved delegation.')],
    discover=CONNECT + """
foreach ($mbx in $Mailbox) {
    $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop
    $current = @($mb.GrantSendOnBehalfTo | ForEach-Object { "$_" })

    foreach ($tr in $Trustee) {
        if ($current -match [regex]::Escape($tr)) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0} -> {1}' -f $tr, $mbx) `
                -Message 'Skipped - already granted (idempotent)'
            continue
        }
        $results.Add([PSCustomObject]@{
            Name         = ('{0} -> {1}' -f $tr, $mb.PrimarySmtpAddress)
            Id           = $mb.Identity
            Mailbox      = $mb.PrimarySmtpAddress
            Trustee      = $tr
            CurrentGrants= ($current -join '; ')
            Ticket       = $TicketReference
            Visibility   = 'Recipients see "Trustee on behalf of Owner"'
        })
    }
}
""",
    act="""
Set-Mailbox -Identity $item.Mailbox -GrantSendOnBehalfTo @{ Add = $item.Trustee } -ErrorAction Stop

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Send on Behalf granted. Ticket={0} Approval={1}' -f $TicketReference, $ApprovalReference)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'SendOnBehalfGranted'; Detail = $item.Mailbox; Succeeded = $true })
"""),

7: dict(
    file='Remove-ExoSendOnBehalf',
    modules=['ExchangeOnlineManagement'],
    synopsis='Removes Send on Behalf Of permission from a mailbox.',
    desc='Revokes a trustee\'s Send on Behalf delegation. Low risk and ticket-driven, so it '
         'executes directly with the prior grant list recorded first.',
    params=[MBX, TRUSTEE],
    perms='Exchange Online Organization Management.',
    actionVerb='Remove Send on Behalf',
    rollback='Re-grant with Add-ExoSendOnBehalf.ps1.',
    examples=[("-Mailbox shared@contoso.com -Trustee leaver@contoso.com",
               'Removes the delegation.'),
              ("-Mailbox shared@contoso.com -Trustee leaver@contoso.com -WhatIf",
               'Shows the change without applying it.')],
    discover=CONNECT + """
foreach ($mbx in $Mailbox) {
    $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop
    $current = @($mb.GrantSendOnBehalfTo | ForEach-Object { "$_" })

    foreach ($tr in $Trustee) {
        if (-not ($current -match [regex]::Escape($tr))) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0} -> {1}' -f $tr, $mbx) `
                -Message 'Skipped - no such delegation (idempotent)'
            continue
        }
        $results.Add([PSCustomObject]@{
            Name         = ('{0} -> {1}' -f $tr, $mb.PrimarySmtpAddress)
            Id           = $mb.Identity
            Mailbox      = $mb.PrimarySmtpAddress
            Trustee      = $tr
            CurrentGrants= ($current -join '; ')
        })
    }
}
""",
    act="""
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Prior grants: {0}' -f $item.CurrentGrants)

Set-Mailbox -Identity $item.Mailbox -GrantSendOnBehalfTo @{ Remove = $item.Trustee } -ErrorAction Stop

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message 'Send on Behalf removed'
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'SendOnBehalfRemoved'; Detail = $item.Mailbox; Succeeded = $true })
"""),

8: dict(
    file='Get-ExoSendOnBehalf',
    modules=['ExchangeOnlineManagement'],
    synopsis='Reports Send on Behalf Of delegations across mailboxes.',
    desc='Lists every mailbox with a Send on Behalf grant and who holds it, for delegation review.',
    params=[dict(name='Mailbox', help='Mailboxes to inspect. All mailboxes when omitted.',
                 decl="[string[]]$Mailbox"),
            dict(name='ResultSize', help='Maximum mailboxes to examine when -Mailbox is omitted.',
                 decl="[int]$ResultSize = 500")],
    perms='Exchange Online View-Only Recipients role.',
    examples=[("-Mailbox shared@contoso.com", 'Delegations on one mailbox.'),
              ("-OutputFormat CSV", 'Tenant-wide delegation export.')],
    discover=CONNECT + """
$mailboxes = if ($Mailbox) { $Mailbox | ForEach-Object { Get-Mailbox -Identity $_ -ErrorAction Stop } }
             else          { Get-Mailbox -ResultSize $ResultSize }

foreach ($mb in $mailboxes) {
    $grants = @($mb.GrantSendOnBehalfTo | ForEach-Object { "$_" })
    if ($grants.Count -eq 0) { continue }

    foreach ($g in $grants) {
        $results.Add([PSCustomObject]@{
            Name        = ('{0} -> {1}' -f $g, $mb.PrimarySmtpAddress)
            Id          = $mb.Identity
            Mailbox     = $mb.PrimarySmtpAddress
            MailboxType = "$($mb.RecipientTypeDetails)"
            Trustee     = $g
            Permission  = 'SendOnBehalf'
            Visibility  = 'Attributed - recipients see the delegate'
        })
    }
}
"""),

9: dict(
    file='Add-ExoFolderPermission',
    modules=['ExchangeOnlineManagement'],
    synopsis='Grants explicit permission on a mailbox folder.',
    desc='Grants folder-level access, typically to a calendar or a shared subfolder. More granular '
         'than Full Access and therefore preferable where it meets the need, but still an access '
         'grant to someone else\'s data, so it is approval-gated.',
    params=[MBX, TRUSTEE,
            dict(name='FolderPath', help='Folder relative to the mailbox root, e.g. :\\\\Calendar or :\\\\Inbox\\\\Shared.',
                 decl="[Parameter(Mandatory)]\n    [string]$FolderPath"),
            dict(name='AccessRight', help='Exchange folder access right to grant.',
                 decl="[ValidateSet('Owner','PublishingEditor','Editor','PublishingAuthor','Author','NonEditingAuthor','Reviewer','Contributor','AvailabilityOnly','LimitedDetails')]\n    [string]$AccessRight = 'Reviewer'")],
    perms='Exchange Online Organization Management, or Mail Recipients role.',
    actionVerb='Grant folder permission',
    reason='Folder permission grant',
    rollback='Remove-ExoFolderPermission.ps1.',
    notes='Reviewer grants read access; Editor allows modification and deletion. The default here '
          'is Reviewer deliberately - escalate only if the request genuinely needs write access.',
    examples=[("-Mailbox user@contoso.com -Trustee peer@contoso.com -FolderPath ':\\\\Calendar' -AccessRight Reviewer -TicketReference REQ0012345",
               'REQUEST mode - raises an approval for calendar read access.'),
              ("-Mailbox user@contoso.com -Trustee peer@contoso.com -FolderPath ':\\\\Calendar' -ApprovalReference APR-...",
               'Applies the approved grant.')],
    discover=CONNECT + """
foreach ($mbx in $Mailbox) {
    $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop
    $folderId = '{0}{1}' -f $mb.PrimarySmtpAddress, $FolderPath

    # Fail early if the folder path is wrong, rather than at grant time.
    try { Get-MailboxFolderPermission -Identity $folderId -ErrorAction Stop | Out-Null }
    catch { throw ('Folder "{0}" not found on {1}: {2}' -f $FolderPath, $mb.PrimarySmtpAddress, $_.Exception.Message) }

    foreach ($tr in $Trustee) {
        $existing = Get-MailboxFolderPermission -Identity $folderId -User $tr -ErrorAction SilentlyContinue
        if ($existing -and $existing.AccessRights -contains $AccessRight) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0} -> {1}' -f $tr, $folderId) `
                -Message ('Skipped - already has {0} (idempotent)' -f $AccessRight)
            continue
        }

        $results.Add([PSCustomObject]@{
            Name          = ('{0} -> {1}{2}' -f $tr, $mb.PrimarySmtpAddress, $FolderPath)
            Id            = $folderId
            Mailbox       = $mb.PrimarySmtpAddress
            FolderPath    = $FolderPath
            FolderId      = $folderId
            Trustee       = $tr
            AccessRight   = $AccessRight
            ExistingRight = if ($existing) { ($existing.AccessRights -join ',') } else { $null }
            IsUpdate      = [bool]$existing
            Ticket        = $TicketReference
        })
    }
}
""",
    act="""
if ($item.IsUpdate) {
    Set-MailboxFolderPermission -Identity $item.FolderId -User $item.Trustee `
        -AccessRights $item.AccessRight -Confirm:$false -ErrorAction Stop | Out-Null
    $verb = 'updated'
} else {
    Add-MailboxFolderPermission -Identity $item.FolderId -User $item.Trustee `
        -AccessRights $item.AccessRight -Confirm:$false -ErrorAction Stop | Out-Null
    $verb = 'granted'
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Folder permission {0}: {1} (was {2}). Ticket={3}' -f
    $verb, $item.AccessRight, $(if ($item.ExistingRight) { $item.ExistingRight } else { 'none' }), $TicketReference)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = ('FolderPermission' + $verb); Detail = $item.AccessRight; Succeeded = $true })
"""),

10: dict(
    file='Remove-ExoFolderPermission',
    modules=['ExchangeOnlineManagement'],
    synopsis='Removes an explicit permission from a mailbox folder.',
    desc='Revokes folder-level access for a trustee. Low risk and ticket-driven, so it executes '
         'directly, recording the prior access right first.',
    params=[MBX, TRUSTEE,
            dict(name='FolderPath', help='Folder relative to the mailbox root, e.g. :\\\\Calendar.',
                 decl="[Parameter(Mandatory)]\n    [string]$FolderPath")],
    perms='Exchange Online Organization Management.',
    actionVerb='Remove folder permission',
    rollback='Re-grant with Add-ExoFolderPermission.ps1 using the access right recorded in the audit log.',
    examples=[("-Mailbox user@contoso.com -Trustee leaver@contoso.com -FolderPath ':\\\\Calendar'",
               'Removes calendar access.'),
              ("-Mailbox user@contoso.com -Trustee leaver@contoso.com -FolderPath ':\\\\Calendar' -WhatIf",
               'Shows the removal without applying it.')],
    discover=CONNECT + """
foreach ($mbx in $Mailbox) {
    $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop
    $folderId = '{0}{1}' -f $mb.PrimarySmtpAddress, $FolderPath

    foreach ($tr in $Trustee) {
        $existing = Get-MailboxFolderPermission -Identity $folderId -User $tr -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0} -> {1}' -f $tr, $folderId) `
                -Message 'Skipped - no explicit permission (idempotent)'
            continue
        }
        $results.Add([PSCustomObject]@{
            Name        = ('{0} -> {1}{2}' -f $tr, $mb.PrimarySmtpAddress, $FolderPath)
            Id          = $folderId
            Mailbox     = $mb.PrimarySmtpAddress
            FolderPath  = $FolderPath
            FolderId    = $folderId
            Trustee     = $tr
            AccessRight = ($existing.AccessRights -join ',')
        })
    }
}
""",
    act="""
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Prior access right captured: {0}' -f $item.AccessRight)

Remove-MailboxFolderPermission -Identity $item.FolderId -User $item.Trustee `
    -Confirm:$false -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message 'Folder permission removed'
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'FolderPermissionRemoved'; Detail = $item.AccessRight; Succeeded = $true })
"""),

11: dict(
    file='Get-ExoFolderPermission',
    modules=['ExchangeOnlineManagement'],
    synopsis='Reports explicit permissions on mailbox folders.',
    desc='Lists folder-level permissions for the specified folders, excluding the Default and '
         'Anonymous entries unless asked for, since those are almost always noise in a review.',
    params=[dict(name='Mailbox', help='Mailboxes to inspect.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Mailbox"),
            dict(name='FolderPath', help='Folders to inspect.',
                 decl="[string[]]$FolderPath = @(':\\\\Calendar', ':\\\\Inbox')"),
            dict(name='IncludeDefault', help='Include the Default and Anonymous pseudo-users.',
                 decl="[switch]$IncludeDefault")],
    perms='Exchange Online View-Only Recipients role.',
    examples=[("-Mailbox user@contoso.com", 'Calendar and Inbox permissions for one mailbox.'),
              ("-Mailbox user@contoso.com -FolderPath ':\\\\Calendar' -IncludeDefault",
               'Calendar only, including the Default entry.')],
    discover=CONNECT + """
foreach ($mbx in $Mailbox) {
    $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop

    foreach ($fp in $FolderPath) {
        $folderId = '{0}{1}' -f $mb.PrimarySmtpAddress, $fp
        $perms = $null
        try { $perms = Get-MailboxFolderPermission -Identity $folderId -ErrorAction Stop }
        catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $folderId `
                -Message ('Folder not found or unreadable: {0}' -f $_.Exception.Message)
            continue
        }

        foreach ($p in $perms) {
            $user = "$($p.User)"
            if (-not $IncludeDefault -and $user -in @('Default','Anonymous')) { continue }

            $results.Add([PSCustomObject]@{
                Name         = ('{0} -> {1}{2}' -f $user, $mb.PrimarySmtpAddress, $fp)
                Id           = $folderId
                Mailbox      = $mb.PrimarySmtpAddress
                FolderPath   = $fp
                Trustee      = $user
                AccessRights = ($p.AccessRights -join ',')
                SharingPermissionFlags = "$($p.SharingPermissionFlags)"
                IsDefault    = ($user -in @('Default','Anonymous'))
            })
        }
    }
}
"""),

12: dict(
    file='Add-ExoSendAsPermission',
    modules=['ExchangeOnlineManagement'],
    synopsis='Grants Send As permission on a mailbox.',
    desc='Allows a trustee to send mail that appears to come FROM the mailbox owner, with no visible '
         'indication that somebody else sent it. That is impersonation, and it is the reason this '
         'row is High risk with strict approval: a Send As grant enables convincing internal phishing.',
    params=[MBX, TRUSTEE],
    perms='Exchange Online Organization Management, or a custom role with Recipient Permissions.',
    actionVerb='Grant Send As',
    reason='Send As permission grant',
    rollback='Remove-ExoSendAsPermission.ps1. Immediately reversible, but any mail already sent '
             'under the owner\\u2019s identity cannot be recalled or re-attributed.',
    notes='Consider Send on Behalf instead wherever it meets the requirement. Send on Behalf is '
          'visibly attributed to the delegate; Send As is indistinguishable from the owner sending '
          'it themselves, including to the recipient and in most audit views.',
    examples=[("-Mailbox shared@contoso.com -Trustee user@contoso.com -TicketReference REQ0012345",
               'REQUEST mode - raises an approval for an impersonation-capable grant.'),
              ("-Mailbox shared@contoso.com -Trustee user@contoso.com -ApprovalReference APR-...",
               'Applies the approved grant.')],
    discover=CONNECT + """
if (-not $TicketReference) {
    throw 'A -TicketReference is required. Send As is impersonation-capable and needs strict approval.'
}

foreach ($mbx in $Mailbox) {
    $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop

    foreach ($tr in $Trustee) {
        $existing = Get-RecipientPermission -Identity $mb.Identity -Trustee $tr -ErrorAction SilentlyContinue |
                    Where-Object { $_.AccessRights -contains 'SendAs' }
        if ($existing) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0} -> {1}' -f $tr, $mbx) `
                -Message 'Skipped - Send As already granted (idempotent)'
            continue
        }

        $results.Add([PSCustomObject]@{
            Name        = ('{0} -> {1}' -f $tr, $mb.PrimarySmtpAddress)
            Id          = $mb.Identity
            Mailbox     = $mb.PrimarySmtpAddress
            MailboxType = "$($mb.RecipientTypeDetails)"
            Trustee     = $tr
            AccessRight = 'SendAs'
            Ticket      = $TicketReference
            RiskNote    = 'IMPERSONATION - mail will appear to come from the owner with no visible delegate'
            Alternative = 'Send on Behalf is visibly attributed and may meet the same need'
        })
    }
}
""",
    act="""
Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
    'Granting IMPERSONATION-capable Send As. Ticket={0} Approval={1}' -f $TicketReference, $ApprovalReference)

Add-RecipientPermission -Identity $item.Mailbox -Trustee $item.Trustee -AccessRights SendAs `
    -Confirm:$false -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message 'Send As granted'
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'SendAsGranted'; Detail = 'impersonation-capable'; Succeeded = $true })
"""),

13: dict(
    file='Remove-ExoSendAsPermission',
    modules=['ExchangeOnlineManagement'],
    synopsis='Removes Send As permission from a mailbox.',
    desc='Revokes a trustee\'s Send As permission. Removing an impersonation-capable grant is the '
         'safe direction, so it executes directly.',
    params=[MBX, TRUSTEE,
            dict(name='RemoveAll', help='Remove every Send As grant on the mailbox, not just the named trustee.',
                 decl="[switch]$RemoveAll")],
    perms='Exchange Online Organization Management.',
    actionVerb='Remove Send As',
    rollback='Re-grant with Add-ExoSendAsPermission.ps1, which is approval-gated.',
    examples=[("-Mailbox shared@contoso.com -Trustee leaver@contoso.com",
               'Removes one trustee\\u2019s Send As.'),
              ("-Mailbox shared@contoso.com -RemoveAll -WhatIf",
               'Shows every Send As grant that would be removed.')],
    discover=CONNECT + """
foreach ($mbx in $Mailbox) {
    $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop

    $perms = Get-RecipientPermission -Identity $mb.Identity -ErrorAction Stop |
             Where-Object { $_.AccessRights -contains 'SendAs' -and "$($_.Trustee)" -ne 'NT AUTHORITY\\\\SELF' }

    if (-not $RemoveAll) {
        $perms = $perms | Where-Object { $Trustee -contains "$($_.Trustee)" }
    }

    foreach ($p in $perms) {
        $results.Add([PSCustomObject]@{
            Name        = ('{0} -> {1}' -f $p.Trustee, $mb.PrimarySmtpAddress)
            Id          = $mb.Identity
            Mailbox     = $mb.PrimarySmtpAddress
            Trustee     = "$($p.Trustee)"
            AccessRight = ($p.AccessRights -join ',')
        })
    }
}
""",
    act="""
Remove-RecipientPermission -Identity $item.Mailbox -Trustee $item.Trustee -AccessRights SendAs `
    -Confirm:$false -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Send As removed - impersonation capability revoked')
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'SendAsRemoved'; Detail = $item.Mailbox; Succeeded = $true })
"""),

14: dict(
    file='Get-ExoSendAsPermission',
    modules=['ExchangeOnlineManagement'],
    synopsis='Reports Send As permissions across mailboxes.',
    desc='Lists every Send As grant in scope. Because Send As is impersonation-capable and leaves '
         'no visible trace in delivered mail, this export is the practical way to audit who can '
         'send as whom.',
    params=[dict(name='Mailbox', help='Mailboxes to inspect. All mailboxes when omitted.',
                 decl="[string[]]$Mailbox"),
            dict(name='ResultSize', help='Maximum mailboxes to examine when -Mailbox is omitted.',
                 decl="[int]$ResultSize = 500")],
    perms='Exchange Online View-Only Recipients role.',
    examples=[("-OutputFormat CSV", 'Tenant-wide Send As audit.'),
              ("-Mailbox shared@contoso.com", 'Send As grants on one mailbox.')],
    discover=CONNECT + """
$mailboxes = if ($Mailbox) { $Mailbox | ForEach-Object { Get-Mailbox -Identity $_ -ErrorAction Stop } }
             else          { Get-Mailbox -ResultSize $ResultSize }

foreach ($mb in $mailboxes) {
    $perms = Get-RecipientPermission -Identity $mb.Identity -ErrorAction SilentlyContinue |
             Where-Object { $_.AccessRights -contains 'SendAs' -and "$($_.Trustee)" -ne 'NT AUTHORITY\\\\SELF' }

    foreach ($p in $perms) {
        $results.Add([PSCustomObject]@{
            Name        = ('{0} -> {1}' -f $p.Trustee, $mb.PrimarySmtpAddress)
            Id          = $mb.Identity
            Mailbox     = $mb.PrimarySmtpAddress
            MailboxType = "$($mb.RecipientTypeDetails)"
            Trustee     = "$($p.Trustee)"
            AccessRights= ($p.AccessRights -join ',')
            RiskNote    = 'Impersonation-capable - sent mail is indistinguishable from the owner'
        })
    }
}
"""),
}

# Use cases 15-25 live in their own module to keep this file readable.
try:
    from spec_exchange2 import EXTRA as _EXTRA
    SPECS.update(_EXTRA)
except ImportError:
    pass
