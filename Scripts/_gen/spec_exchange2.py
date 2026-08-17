# -*- coding: utf-8 -*-
"""Exchange & O365 - use cases 15-25."""

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

GRAPH = """
Connect-MgGraph -Scopes '{0}' -NoWelcome -ErrorAction Stop
Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'
"""

EXTRA = {

15: dict(
    file='Move-ExoMailboxToCloud',
    modules=['ExchangeOnlineManagement'],
    synopsis='Runs and reports on hybrid mailbox migration batches.',
    desc='Creates and monitors migration batches moving mailboxes from on-premises Exchange to '
         'Exchange Online. The mechanical work - batch creation, status polling, per-mailbox '
         'progress - is automated. Planning, cutover scheduling, user communications and resolving '
         'individual mailbox failures remain human project work, exactly as the workbook states.',
    params=[dict(name='BatchName', help='Migration batch name.',
                 decl="[Parameter(Mandatory)]\n    [string]$BatchName"),
            dict(name='MailboxCsvPath', help='CSV of mailboxes to migrate, with an EmailAddress column.',
                 decl="[string]$MailboxCsvPath"),
            dict(name='MigrationEndpointName', help='Existing migration endpoint to use.',
                 decl="[string]$MigrationEndpointName"),
            dict(name='TargetDeliveryDomain', help='Tenant routing domain, e.g. contoso.mail.onmicrosoft.com.',
                 decl="[string]$TargetDeliveryDomain"),
            dict(name='Mode', help='Status reports on an existing batch; Create makes a new one; Complete finalises the cutover.',
                 decl="[ValidateSet('Status','Create','Complete')]\n    [string]$Mode = 'Status'"),
            dict(name='AutoComplete', help='Allow the batch to complete automatically. Off by default - cutover timing is a human decision.',
                 decl="[switch]$AutoComplete")],
    minage=0,
    perms='Exchange Online Organization Management plus Mailbox Import Export role.',
    actionVerb='Create or complete migration batch',
    reason='Hybrid mailbox migration',
    rollback='An incomplete batch can be removed with Remove-MigrationBatch, leaving the source '
             'mailbox authoritative. Once a batch COMPLETES, the mailbox has moved and reversing it '
             'requires a fresh migration in the opposite direction. Completion is the point of no '
             'easy return, which is why it needs both approval and -Execute.',
    notes='-Mode Status is read-only and needs no approval. Create and Complete are gated. '
          'AutoComplete is off by default because completing a batch cuts users over, and the '
          'timing of that is a project decision rather than an automation one.',
    examples=[("-BatchName wave3 -Mode Status",
               'Reports progress of an existing batch. Changes nothing.'),
              ("-BatchName wave3 -Mode Create -MailboxCsvPath .\\\\wave3.csv -MigrationEndpointName onprem -TargetDeliveryDomain contoso.mail.onmicrosoft.com -ApprovalReference APR-... -Execute",
               'Creates the approved migration batch.')],
    discover=CONNECT + """
if ($Mode -eq 'Status') {
    $batches = if ($BatchName) { @(Get-MigrationBatch -Identity $BatchName -ErrorAction Stop) }
               else            { @(Get-MigrationBatch) }

    foreach ($b in $batches) {
        $users = @(Get-MigrationUser -BatchId $b.Identity -ErrorAction SilentlyContinue)
        $failed = @($users | Where-Object { $_.Status -eq 'Failed' })
        $synced = @($users | Where-Object { $_.Status -in @('Synced','Completed') })

        $results.Add([PSCustomObject]@{
            Name          = $b.Identity
            Id            = $b.Identity
            BatchStatus   = "$($b.Status)"
            TotalMailboxes= $users.Count
            Synced        = $synced.Count
            Failed        = $failed.Count
            FailedMailboxes = (($failed.Identity | Select-Object -First 20) -join '; ')
            PercentComplete = if ($users.Count -gt 0) { [math]::Round(($synced.Count / $users.Count) * 100, 1) } else { 0 }
            CreationTime  = $b.CreationDateTime
            HumanFollowUp = 'Per-mailbox failures need individual investigation - not automated'
        })
        if ($failed.Count -gt 0) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $b.Identity `
                -Message ('{0} mailbox(es) failed and need human investigation' -f $failed.Count)
        }
    }
    return
}

if ($Mode -eq 'Create') {
    foreach ($p in @('MailboxCsvPath','MigrationEndpointName','TargetDeliveryDomain')) {
        if (-not (Get-Variable -Name $p -ValueOnly)) { throw ('-{0} is required when -Mode is Create.' -f $p) }
    }
    if (-not (Test-Path -LiteralPath $MailboxCsvPath)) { throw ('CSV not found: {0}' -f $MailboxCsvPath) }
    if (Get-MigrationBatch -Identity $BatchName -ErrorAction SilentlyContinue) {
        throw ('Migration batch {0} already exists. Use -Mode Status, or choose another name.' -f $BatchName)
    }

    $rows = Import-Csv -LiteralPath $MailboxCsvPath
    if (-not ($rows | Get-Member -Name EmailAddress)) {
        throw 'The CSV must contain an EmailAddress column.'
    }

    $results.Add([PSCustomObject]@{
        Name          = $BatchName
        Id            = $BatchName
        Mode          = 'Create'
        MailboxCount  = @($rows).Count
        CsvPath       = $MailboxCsvPath
        Endpoint      = $MigrationEndpointName
        TargetDomain  = $TargetDeliveryDomain
        AutoComplete  = [bool]$AutoComplete
        Mailboxes     = (($rows.EmailAddress | Select-Object -First 25) -join '; ')
    })
    return
}

# Complete
$batch = Get-MigrationBatch -Identity $BatchName -ErrorAction Stop
if ($batch.Status -ne 'Synced') {
    throw ('Batch {0} is {1}, not Synced. Completing an unsynced batch loses mail.' -f $BatchName, $batch.Status)
}
$users = @(Get-MigrationUser -BatchId $batch.Identity -ErrorAction SilentlyContinue)
$failed = @($users | Where-Object { $_.Status -eq 'Failed' })
if ($failed.Count -gt 0) {
    throw ('Batch {0} has {1} failed mailbox(es). Resolve them before completing the cutover.' -f $BatchName, $failed.Count)
}

$results.Add([PSCustomObject]@{
    Name          = $BatchName
    Id            = $BatchName
    Mode          = 'Complete'
    BatchStatus   = "$($batch.Status)"
    MailboxCount  = $users.Count
    CutoverImpact = 'Users are moved to the cloud mailbox. Reversal requires a fresh migration.'
})
""",
    act="""
if ($item.Mode -eq 'Create') {
    New-MigrationBatch -Name $item.Name -SourceEndpoint $item.Endpoint `
        -CSVData ([System.IO.File]::ReadAllBytes($item.CsvPath)) `
        -TargetDeliveryDomain $item.TargetDomain -AutoStart `
        -AutoComplete:$item.AutoComplete -ErrorAction Stop | Out-Null

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Migration batch created and started: {0} mailbox(es), autocomplete={1}. ' +
        'Monitor with -Mode Status.' -f $item.MailboxCount, $item.AutoComplete)
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'BatchCreated'
        Detail = ('{0} mailboxes' -f $item.MailboxCount); Succeeded = $true })
} else {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
        'COMPLETING migration batch - users cut over to the cloud. Approval={0} Ticket={1}' -f
        $ApprovalReference, $TicketReference)

    Complete-MigrationBatch -Identity $item.Name -Confirm:$false -ErrorAction Stop | Out-Null

    Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
        'Batch completion requested for {0} mailbox(es)' -f $item.MailboxCount)
    $actions.Add([PSCustomObject]@{
        Name = $item.Name; Action = 'BatchCompleted'
        Detail = ('{0} mailboxes cut over' -f $item.MailboxCount); Succeeded = $true })
}
"""),

16: dict(
    file='Set-O365UserLicense',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Users.Actions'],
    synopsis='Adds or removes Microsoft 365 licences for a user.',
    desc='Assigns or removes licences. Removal is the dangerous direction: stripping a licence '
         'starts a retention clock on the associated mailbox and OneDrive data, so removals are '
         'approval-gated and the script reports what each licence carries before acting.',
    params=[dict(name='UserPrincipalName', help='User(s) to change.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$UserPrincipalName"),
            dict(name='Operation', help='Add or Remove.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Add','Remove')]\n    [string]$Operation"),
            dict(name='SkuPartNumber', help='Licence SKU part number, e.g. ENTERPRISEPACK, SPE_E3.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$SkuPartNumber")],
    perms='Microsoft Graph User.ReadWrite.All and Organization.Read.All.',
    actionVerb='Change user licence',
    reason='Licence assignment change',
    rollback='Re-assign the licence. Data is retained for 30 days after removal, so a prompt '
             're-assignment restores access - but after 30 days the mailbox and OneDrive content '
             'are permanently deleted.',
    notes='Removing an Exchange-bearing licence soft-deletes the mailbox after the retention window. '
          'For a leaver, convert to a shared mailbox first, then remove the licence - that keeps the '
          'mail without consuming a seat.',
    examples=[("-UserPrincipalName user@contoso.com -Operation Remove -SkuPartNumber ENTERPRISEPACK -TicketReference REQ0012345",
               'REQUEST mode - raises an approval for a licence removal.'),
              ("-UserPrincipalName user@contoso.com -Operation Add -SkuPartNumber ENTERPRISEPACK -ApprovalReference APR-...",
               'Applies the approved assignment.')],
    discover=GRAPH.format("User.ReadWrite.All','Organization.Read.All") + """
$skus = Get-MgSubscribedSku -All -ErrorAction Stop

foreach ($upn in $UserPrincipalName) {
    $u = Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName,AssignedLicenses,UsageLocation -ErrorAction Stop

    foreach ($part in $SkuPartNumber) {
        $sku = $skus | Where-Object SkuPartNumber -eq $part | Select-Object -First 1
        if (-not $sku) { throw ('SKU {0} is not present in this tenant.' -f $part) }

        $has = $u.AssignedLicenses.SkuId -contains $sku.SkuId
        if (($Operation -eq 'Add' -and $has) -or ($Operation -eq 'Remove' -and -not $has)) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $upn `
                -Message ('Skipped - licence {0} already in the requested state (idempotent)' -f $part)
            continue
        }

        # Assignment fails without a usage location, and the error is unhelpful.
        if ($Operation -eq 'Add' -and -not $u.UsageLocation) {
            throw ('{0} has no UsageLocation set. Licence assignment will fail until it is set.' -f $upn)
        }

        $available = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
        if ($Operation -eq 'Add' -and $available -le 0) {
            throw ('No available seats for {0} ({1} of {2} consumed).' -f $part, $sku.ConsumedUnits, $sku.PrepaidUnits.Enabled)
        }

        $results.Add([PSCustomObject]@{
            Name           = ('{0} : {1} {2}' -f $u.UserPrincipalName, $Operation, $part)
            Id             = $u.Id
            UserPrincipalName = $u.UserPrincipalName
            DisplayName    = $u.DisplayName
            Operation      = $Operation
            SkuPartNumber  = $part
            SkuId          = $sku.SkuId
            SeatsAvailable = $available
            ServicePlans   = (($sku.ServicePlans.ServicePlanName | Select-Object -First 12) -join '; ')
            DataRisk       = if ($Operation -eq 'Remove') {
                                 'Removing this licence starts a 30-day retention clock on any mailbox and OneDrive data it provides'
                             } else { 'Additive' }
        })
    }
}
""",
    act="""
if ($item.Operation -eq 'Add') {
    Set-MgUserLicense -UserId $item.Id -AddLicenses @(@{ SkuId = $item.SkuId }) -RemoveLicenses @() -ErrorAction Stop | Out-Null
    $detail = 'licence {0} assigned' -f $item.SkuPartNumber
} else {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
        'Removing licence {0} - 30-day retention clock starts on associated data. Approval={1}' -f
        $item.SkuPartNumber, $ApprovalReference)
    Set-MgUserLicense -UserId $item.Id -AddLicenses @() -RemoveLicenses @($item.SkuId) -ErrorAction Stop | Out-Null
    $detail = 'licence {0} removed' -f $item.SkuPartNumber
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message $detail
$actions.Add([PSCustomObject]@{ Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
"""),

17: dict(
    file='Set-ExoMailboxDelegation',
    modules=['ExchangeOnlineManagement'],
    synopsis='Adds or removes combined mailbox delegation in one operation.',
    desc='Applies the delegation set an assistant typically needs - Full Access, Send on Behalf and '
         'calendar Editor - as a single reviewable change, rather than three separate requests that '
         'get approved at different times and drift apart.',
    params=[dict(name='Mailbox', help='Mailbox being delegated.',
                 decl="[Parameter(Mandatory)]\n    [string]$Mailbox"),
            dict(name='Delegate', help='User receiving the delegation.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Delegate"),
            dict(name='Operation', help='Add or Remove.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Add','Remove')]\n    [string]$Operation"),
            dict(name='IncludeFullAccess', help='Include Full Access in the delegation set.',
                 decl="[bool]$IncludeFullAccess = $true"),
            dict(name='IncludeSendOnBehalf', help='Include Send on Behalf in the delegation set.',
                 decl="[bool]$IncludeSendOnBehalf = $true"),
            dict(name='CalendarRight', help='Calendar access right to apply. None skips the calendar.',
                 decl="[ValidateSet('None','Reviewer','Author','Editor')]\n    [string]$CalendarRight = 'Editor'")],
    perms='Exchange Online Organization Management.',
    actionVerb='Change mailbox delegation',
    reason='Mailbox delegation change',
    rollback='Re-run with the opposite -Operation. The full delegation set applied is recorded in '
             'the audit log so it can be reproduced exactly.',
    notes='Send As is deliberately NOT part of this set. It is impersonation-capable and has its own '
          'approval path in Add-ExoSendAsPermission.ps1; bundling it into a routine delegation '
          'request would let it through on weaker scrutiny.',
    examples=[("-Mailbox exec@contoso.com -Delegate assistant@contoso.com -Operation Add -TicketReference REQ0012345",
               'REQUEST mode - raises an approval for the full delegation set.'),
              ("-Mailbox exec@contoso.com -Delegate assistant@contoso.com -Operation Remove -ApprovalReference APR-...",
               'Removes the approved delegation set.')],
    discover=CONNECT + """
$mb = Get-Mailbox -Identity $Mailbox -ErrorAction Stop

foreach ($d in $Delegate) {
    $components = @()
    if ($IncludeFullAccess)   { $components += 'FullAccess' }
    if ($IncludeSendOnBehalf) { $components += 'SendOnBehalf' }
    if ($CalendarRight -ne 'None') { $components += ('Calendar:{0}' -f $CalendarRight) }
    if ($components.Count -eq 0) { throw 'Nothing to do - every delegation component is disabled.' }

    $results.Add([PSCustomObject]@{
        Name        = ('{0} -> {1}' -f $d, $mb.PrimarySmtpAddress)
        Id          = $mb.Identity
        Mailbox     = $mb.PrimarySmtpAddress
        Delegate    = $d
        Operation   = $Operation
        Components  = ($components -join ', ')
        FullAccess  = $IncludeFullAccess
        SendOnBehalf= $IncludeSendOnBehalf
        CalendarRight = $CalendarRight
        Excluded    = 'Send As is NOT included - it has its own approval path'
    })
}
""",
    act="""
$applied = @()

if ($item.FullAccess) {
    if ($item.Operation -eq 'Add') {
        Add-MailboxPermission -Identity $item.Mailbox -User $item.Delegate -AccessRights FullAccess `
            -AutoMapping:$false -Confirm:$false -ErrorAction Stop | Out-Null
    } else {
        Remove-MailboxPermission -Identity $item.Mailbox -User $item.Delegate -AccessRights FullAccess `
            -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    $applied += 'FullAccess'
}

if ($item.SendOnBehalf) {
    if ($item.Operation -eq 'Add') {
        Set-Mailbox -Identity $item.Mailbox -GrantSendOnBehalfTo @{ Add = $item.Delegate } -ErrorAction Stop
    } else {
        Set-Mailbox -Identity $item.Mailbox -GrantSendOnBehalfTo @{ Remove = $item.Delegate } -ErrorAction SilentlyContinue
    }
    $applied += 'SendOnBehalf'
}

if ($item.CalendarRight -ne 'None') {
    $calId = '{0}:\\Calendar' -f $item.Mailbox
    if ($item.Operation -eq 'Add') {
        $existing = Get-MailboxFolderPermission -Identity $calId -User $item.Delegate -ErrorAction SilentlyContinue
        if ($existing) {
            Set-MailboxFolderPermission -Identity $calId -User $item.Delegate `
                -AccessRights $item.CalendarRight -Confirm:$false -ErrorAction Stop | Out-Null
        } else {
            Add-MailboxFolderPermission -Identity $calId -User $item.Delegate `
                -AccessRights $item.CalendarRight -Confirm:$false -ErrorAction Stop | Out-Null
        }
    } else {
        Remove-MailboxFolderPermission -Identity $calId -User $item.Delegate `
            -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    $applied += ('Calendar:{0}' -f $item.CalendarRight)
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Delegation {0}: {1}. Ticket={2}' -f $item.Operation.ToLower(), ($applied -join ', '), $TicketReference)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = ('Delegation' + $item.Operation)
    Detail = ($applied -join ', '); Succeeded = $true })
"""),

18: dict(
    file='New-ExoDistributionGroup',
    modules=['ExchangeOnlineManagement'],
    synopsis='Creates a distribution group with enforced naming and ownership.',
    desc='Creates a distribution group only if the name matches the configured convention and an '
         'owner is supplied. Additive and low risk, but the naming and ownership standards are '
         'enforced in code - an ownerless group is the one nobody maintains.',
    params=[dict(name='GroupName', help='Display name of the group to create.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$GroupName"),
            dict(name='PrimarySmtpAddress', help='Primary SMTP address. Derived from the name when omitted.',
                 decl="[string]$PrimarySmtpAddress"),
            dict(name='ManagedBy', help='Group owner(s). At least one is required.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$ManagedBy"),
            dict(name='Members', help='Initial members.',
                 decl="[string[]]$Members"),
            dict(name='NamingPattern', help='Wildcard pattern the display name must match. Set to * to disable.',
                 decl="[string]$NamingPattern = 'DL-*'"),
            dict(name='RequireSenderAuthentication', help='Reject mail from outside the organisation. On by default.',
                 decl="[bool]$RequireSenderAuthentication = $true")],
    perms='Exchange Online Recipient Management role.',
    actionVerb='Create distribution group',
    rollback='Remove-DistributionGroup. A newly created empty group can be removed safely.',
    notes='RequireSenderAuthentication defaults to true, so the group does not accept external mail. '
          'Open distribution groups are a common spam and spoofing vector; turn it off only where '
          'external senders genuinely need to post.',
    examples=[("-GroupName 'DL-Finance' -ManagedBy owner@contoso.com -Members a@contoso.com,b@contoso.com",
               'Creates a compliant distribution group.'),
              ("-GroupName 'Finance' -ManagedBy owner@contoso.com -WhatIf",
               'Fails the naming check before doing anything.')],
    discover=CONNECT + """
foreach ($name in $GroupName) {
    if ($NamingPattern -ne '*' -and $name -notlike $NamingPattern) {
        throw ('Refusing to create "{0}": it does not match the naming pattern "{1}".' -f $name, $NamingPattern)
    }

    $smtp = if ($PrimarySmtpAddress) { $PrimarySmtpAddress }
            else { '{0}@{1}' -f ($name -replace '[^\\w-]', ''), (($ManagedBy[0] -split '@')[1]) }

    if (Get-DistributionGroup -Identity $name -ErrorAction SilentlyContinue) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $name `
            -Message 'Skipped - group already exists (idempotent)'
        continue
    }

    # Verify owners exist before creating, so a typo does not leave an
    # ownerless group behind.
    foreach ($owner in $ManagedBy) {
        if (-not (Get-Recipient -Identity $owner -ErrorAction SilentlyContinue)) {
            throw ('Owner {0} does not exist. Refusing to create an ownerless group.' -f $owner)
        }
    }

    $results.Add([PSCustomObject]@{
        Name         = $name
        Id           = $name
        GroupName    = $name
        PrimarySmtp  = $smtp
        ManagedBy    = ($ManagedBy -join '; ')
        MemberCount  = @($Members).Count
        Members      = ($Members -join '; ')
        RequireSenderAuth = $RequireSenderAuthentication
    })
}
""",
    act="""
New-DistributionGroup -Name $item.GroupName -PrimarySmtpAddress $item.PrimarySmtp `
    -ManagedBy $ManagedBy -Type Distribution -ErrorAction Stop | Out-Null

Set-DistributionGroup -Identity $item.GroupName `
    -RequireSenderAuthenticationEnabled $item.RequireSenderAuth -ErrorAction Stop

$added = 0
foreach ($m in $Members) {
    try {
        Add-DistributionGroupMember -Identity $item.GroupName -Member $m -ErrorAction Stop
        $added++
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
            -Message ('Could not add member {0}: {1}' -f $m, $_.Exception.Message)
    }
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Group created: {0}, {1} member(s) added, external senders {2}' -f
    $item.PrimarySmtp, $added, $(if ($item.RequireSenderAuth) { 'blocked' } else { 'ALLOWED' }))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'GroupCreated'
    Detail = ('{0}; {1} members' -f $item.PrimarySmtp, $added); Succeeded = $true })
"""),

19: dict(
    file='Convert-ExoSharedMailbox',
    modules=['ExchangeOnlineManagement'],
    synopsis='Converts a user mailbox to a shared mailbox, or back.',
    desc='Changes mailbox type. Converting to shared is the standard leaver pattern: the mail stays '
         'accessible and the licence can be released. Converting back to a user mailbox requires a '
         'licence, and the script refuses if none is available rather than leaving the mailbox in a '
         'broken state.',
    params=[dict(name='Mailbox', help='Mailbox to convert.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Mailbox"),
            dict(name='TargetType', help='Shared or Regular.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Shared','Regular')]\n    [string]$TargetType"),
            dict(name='BlockSignIn', help='Also block sign-in for the associated account when converting to shared.',
                 decl="[switch]$BlockSignIn")],
    perms='Exchange Online Recipient Management. -BlockSignIn additionally needs Graph User.ReadWrite.All.',
    actionVerb='Convert mailbox type',
    reason='Mailbox type conversion',
    rollback='Convert back with the opposite -TargetType. Converting to Regular requires an '
             'available licence within 30 days, after which the mailbox is removed.',
    notes='A shared mailbox over 50GB requires a licence to stay accessible. The script reports '
          'current size so a large mailbox is not silently converted into one that stops working.',
    examples=[("-Mailbox leaver@contoso.com -TargetType Shared -TicketReference REQ0012345",
               'REQUEST mode - raises an approval for the leaver conversion.'),
              ("-Mailbox leaver@contoso.com -TargetType Shared -ApprovalReference APR-... -BlockSignIn",
               'Converts and blocks sign-in.')],
    discover=CONNECT + """
foreach ($mbx in $Mailbox) {
    $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop
    $currentType = "$($mb.RecipientTypeDetails)"

    $wanted = if ($TargetType -eq 'Shared') { 'SharedMailbox' } else { 'UserMailbox' }
    if ($currentType -eq $wanted) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $mbx `
            -Message ('Skipped - already {0} (idempotent)' -f $currentType)
        continue
    }

    $stats = Get-MailboxStatistics -Identity $mb.Identity -ErrorAction SilentlyContinue
    $sizeGB = $null
    if ($stats -and "$($stats.TotalItemSize)" -match '\\(([\\d,]+) bytes\\)') {
        $sizeGB = [math]::Round(([double]($Matches[1] -replace ',', '')) / 1GB, 2)
    }

    $warnings = @()
    if ($TargetType -eq 'Shared' -and $null -ne $sizeGB -and $sizeGB -gt 50) {
        $warnings += ('mailbox is {0}GB - a shared mailbox above 50GB still needs a licence' -f $sizeGB)
    }
    if ($TargetType -eq 'Regular') {
        $warnings += 'converting to a user mailbox requires an available licence'
    }

    $results.Add([PSCustomObject]@{
        Name        = $mb.PrimarySmtpAddress
        Id          = $mb.Identity
        DisplayName = $mb.DisplayName
        CurrentType = $currentType
        TargetType  = $wanted
        SizeGB      = $sizeGB
        BlockSignIn = [bool]$BlockSignIn
        Warnings    = ($warnings -join '; ')
    })
    if ($warnings.Count) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $mbx -Message ($warnings -join '; ')
    }
}
""",
    act="""
Set-Mailbox -Identity $item.Id -Type $TargetType -ErrorAction Stop

if ($BlockSignIn -and $TargetType -eq 'Shared') {
    try {
        Connect-MgGraph -Scopes 'User.ReadWrite.All' -NoWelcome -ErrorAction Stop
        $u = Get-MgUser -UserId $item.Name -Property Id -ErrorAction Stop
        Update-MgUser -UserId $u.Id -AccountEnabled:$false -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message 'Sign-in blocked'
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
            -Message ('Converted, but sign-in could not be blocked: {0}' -f $_.Exception.Message)
    }
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Converted {0} -> {1}. Size {2}GB. Ticket={3}' -f
    $item.CurrentType, $item.TargetType, $item.SizeGB, $TicketReference)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Converted'
    Detail = ('{0} -> {1}' -f $item.CurrentType, $item.TargetType); Succeeded = $true })
"""),

20: dict(
    file='Add-O365GroupMember',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Groups'],
    synopsis='Adds or removes a user from a Microsoft 365 group.',
    desc='Changes group membership. A group can carry Teams access, SharePoint permissions and '
         'application assignments, so the script reports what the group grants before the change is '
         'approved - membership is rarely just membership.',
    params=[dict(name='GroupName', help='Group display name or object id.',
                 decl="[Parameter(Mandatory)]\n    [string]$GroupName"),
            dict(name='UserPrincipalName', help='User(s) to add or remove.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$UserPrincipalName"),
            dict(name='Operation', help='Add or Remove.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Add','Remove')]\n    [string]$Operation")],
    perms='Microsoft Graph GroupMember.ReadWrite.All and Group.Read.All.',
    actionVerb='Change group membership',
    reason='Group membership change',
    rollback='Re-run with the opposite -Operation.',
    notes='A dynamic group\\u2019s membership is computed from its rule, so it cannot be edited '
          'directly. The script detects that and refuses with a clear message rather than failing '
          'inside Graph.',
    examples=[("-GroupName 'Finance Team' -UserPrincipalName user@contoso.com -Operation Add -TicketReference REQ0012345",
               'REQUEST mode - raises an approval showing what the group grants.'),
              ("-GroupName 'Finance Team' -UserPrincipalName user@contoso.com -Operation Remove -ApprovalReference APR-...",
               'Applies the approved change.')],
    discover=GRAPH.format("Group.Read.All','GroupMember.ReadWrite.All','User.Read.All") + """
$group = Get-MgGroup -Filter ("displayName eq '{0}'" -f ($GroupName -replace "'", "''")) -ErrorAction SilentlyContinue |
         Select-Object -First 1
if (-not $group) {
    $group = Get-MgGroup -GroupId $GroupName -ErrorAction SilentlyContinue
}
if (-not $group) { throw ('Group "{0}" not found.' -f $GroupName) }

# Dynamic membership is rule-driven and cannot be edited member by member.
if ($group.GroupTypes -contains 'DynamicMembership') {
    throw ('"{0}" uses dynamic membership. Edit the membership rule instead - direct changes are not possible.' -f $group.DisplayName)
}

$members = @(Get-MgGroupMember -GroupId $group.Id -All -ErrorAction SilentlyContinue)

foreach ($upn in $UserPrincipalName) {
    $u = Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName -ErrorAction Stop
    $isMember = $members.Id -contains $u.Id

    if (($Operation -eq 'Add' -and $isMember) -or ($Operation -eq 'Remove' -and -not $isMember)) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $upn `
            -Message ('Skipped - membership already in the requested state (idempotent)' )
        continue
    }

    $results.Add([PSCustomObject]@{
        Name          = ('{0} : {1} {2}' -f $u.UserPrincipalName, $Operation, $group.DisplayName)
        Id            = $group.Id
        GroupName     = $group.DisplayName
        GroupId       = $group.Id
        GroupTypes    = ($group.GroupTypes -join ',')
        MailEnabled   = $group.MailEnabled
        SecurityEnabled = $group.SecurityEnabled
        CurrentMembers= $members.Count
        UserPrincipalName = $u.UserPrincipalName
        UserId        = $u.Id
        Operation     = $Operation
        AccessNote    = if ($group.SecurityEnabled) { 'Security-enabled - may grant application or data access beyond mail' }
                        else { 'Mail/collaboration group' }
    })
}
""",
    act="""
if ($item.Operation -eq 'Add') {
    New-MgGroupMember -GroupId $item.GroupId -DirectoryObjectId $item.UserId -ErrorAction Stop
    $detail = 'added to {0}' -f $item.GroupName
} else {
    Remove-MgGroupMemberByRef -GroupId $item.GroupId -DirectoryObjectId $item.UserId -ErrorAction Stop
    $detail = 'removed from {0}' -f $item.GroupName
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0}. Group grants: {1}. Ticket={2}' -f $detail, $item.AccessNote, $TicketReference)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
"""),

21: dict(
    file='Set-ExoMailboxForwarding',
    modules=['ExchangeOnlineManagement'],
    synopsis='Configures or removes mailbox forwarding, with external-destination checks.',
    desc='Sets or clears mail forwarding. Forwarding to an external address is a recognised data '
         'exfiltration technique and one of the first things an attacker configures after '
         'compromising a mailbox, so external destinations require approval and are checked against '
         'the tenant\'s outbound anti-spam policy before being proposed.',
    params=[dict(name='Mailbox', help='Mailbox to configure.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Mailbox"),
            dict(name='Operation', help='Set or Remove forwarding.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Set','Remove')]\n    [string]$Operation"),
            dict(name='ForwardingAddress', help='Destination address. Required for Set.',
                 decl="[string]$ForwardingAddress"),
            dict(name='DeliverAndForward', help='Keep a copy in the original mailbox. On by default - forwarding without a local copy hides the mail from the owner.',
                 decl="[bool]$DeliverAndForward = $true"),
            dict(name='AllowExternal', help='Permit forwarding to a domain outside the tenant. Off by default.',
                 decl="[switch]$AllowExternal")],
    perms='Exchange Online Recipient Management.',
    actionVerb='Change mailbox forwarding',
    reason='Mailbox forwarding change',
    rollback='Re-run with -Operation Remove, or restore the previous destination, which is recorded '
             'in the audit log before the change.',
    notes='DeliverAndForward defaults to true. Forwarding WITHOUT a local copy means the mailbox '
          'owner never sees the mail, which is the configuration used to hide activity from the '
          'victim during a compromise.',
    examples=[("-Mailbox user@contoso.com -Operation Set -ForwardingAddress colleague@contoso.com -TicketReference REQ0012345",
               'REQUEST mode - internal forwarding, raises an approval.'),
              ("-Mailbox user@contoso.com -Operation Remove -ApprovalReference APR-...",
               'Removes forwarding.')],
    discover=CONNECT + """
if ($Operation -eq 'Set' -and -not $ForwardingAddress) {
    throw '-ForwardingAddress is required when -Operation is Set.'
}

$acceptedDomains = @((Get-AcceptedDomain -ErrorAction SilentlyContinue).DomainName)

foreach ($mbx in $Mailbox) {
    $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop

    $isExternal = $false
    if ($Operation -eq 'Set') {
        $destDomain = ($ForwardingAddress -split '@')[-1]
        $isExternal = ($acceptedDomains -notcontains $destDomain)

        if ($isExternal) {
            if (-not $AllowExternal) {
                throw ('Refusing: {0} is outside the tenant''s accepted domains. Pass -AllowExternal ' +
                       'and obtain approval if external forwarding is genuinely required.' -f $ForwardingAddress)
            }
            # Tenant policy may block it anyway - better to say so now than to
            # set a rule that silently never delivers.
            $outbound = Get-HostedOutboundSpamFilterPolicy -ErrorAction SilentlyContinue |
                        Select-Object -First 1
            if ($outbound -and "$($outbound.AutoForwardingMode)" -eq 'Off') {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $mbx -Message (
                    'Tenant outbound policy has AutoForwardingMode=Off. External forwarding will be blocked in transport ' +
                    'even once this mailbox setting is applied.')
            }
        }
    }

    $results.Add([PSCustomObject]@{
        Name             = $mb.PrimarySmtpAddress
        Id               = $mb.Identity
        Operation        = $Operation
        CurrentForwarding= if ($mb.ForwardingSmtpAddress) { "$($mb.ForwardingSmtpAddress)" }
                           elseif ($mb.ForwardingAddress) { "$($mb.ForwardingAddress)" } else { $null }
        CurrentDeliverAndForward = $mb.DeliverToMailboxAndForward
        NewForwarding    = if ($Operation -eq 'Set') { $ForwardingAddress } else { $null }
        DeliverAndForward= $DeliverAndForward
        IsExternal       = $isExternal
        RiskNote         = if ($isExternal) { 'EXTERNAL FORWARDING - recognised data exfiltration vector' }
                           elseif ($Operation -eq 'Set') { 'Internal forwarding' }
                           else { 'Removing forwarding' }
    })
}
""",
    act="""
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Prior forwarding: {0} (deliver and forward: {1})' -f
    $(if ($item.CurrentForwarding) { $item.CurrentForwarding } else { 'none' }), $item.CurrentDeliverAndForward)

if ($item.Operation -eq 'Set') {
    if ($item.IsExternal) {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
            'Setting EXTERNAL forwarding to {0}. Approval={1} Ticket={2}' -f
            $item.NewForwarding, $ApprovalReference, $TicketReference)
    }
    Set-Mailbox -Identity $item.Id -ForwardingSmtpAddress $item.NewForwarding `
        -DeliverToMailboxAndForward $item.DeliverAndForward -ErrorAction Stop
    $detail = 'forwarding to {0} (local copy: {1})' -f $item.NewForwarding, $item.DeliverAndForward
} else {
    Set-Mailbox -Identity $item.Id -ForwardingSmtpAddress $null -ForwardingAddress $null `
        -DeliverToMailboxAndForward $true -ErrorAction Stop
    $detail = 'forwarding removed'
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message $detail
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
"""),

22: dict(
    file='Set-ExoMailboxAlias',
    modules=['ExchangeOnlineManagement'],
    synopsis='Adds or removes an email alias on a mailbox.',
    desc='Manages secondary SMTP addresses. Low risk and ticket-driven, so it executes directly - '
         'but the script refuses to remove the primary address, which would break mail flow to the '
         'mailbox entirely.',
    params=[dict(name='Mailbox', help='Mailbox to modify.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Mailbox"),
            dict(name='Alias', help='Alias address(es) to add or remove.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Alias"),
            dict(name='Operation', help='Add or Remove.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Add','Remove')]\n    [string]$Operation")],
    perms='Exchange Online Recipient Management.',
    actionVerb='Change mailbox alias',
    rollback='Re-run with the opposite -Operation. The full prior address list is recorded first.',
    notes='Removing an alias that external senders still use causes silent non-delivery. Check '
         'message trace for recent traffic to the alias before removing it.',
    examples=[("-Mailbox user@contoso.com -Alias sales@contoso.com -Operation Add",
               'Adds an alias.'),
              ("-Mailbox user@contoso.com -Alias old@contoso.com -Operation Remove -WhatIf",
               'Shows the removal without applying it.')],
    discover=CONNECT + """
$acceptedDomains = @((Get-AcceptedDomain -ErrorAction SilentlyContinue).DomainName)

foreach ($mbx in $Mailbox) {
    $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop
    $current = @($mb.EmailAddresses | ForEach-Object { "$_" })

    foreach ($a in $Alias) {
        $smtpEntry = 'smtp:{0}' -f $a
        $primaryEntry = 'SMTP:{0}' -f $a

        # Never remove the primary - that breaks mail flow to the mailbox.
        if ($Operation -eq 'Remove' -and ($current -ccontains $primaryEntry)) {
            throw ('Refusing to remove {0} - it is the PRIMARY address of {1}. Change the primary first.' -f
                   $a, $mb.PrimarySmtpAddress)
        }

        $exists = $current | Where-Object { $_ -ieq $smtpEntry -or $_ -ieq $primaryEntry }
        if (($Operation -eq 'Add' -and $exists) -or ($Operation -eq 'Remove' -and -not $exists)) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0} : {1}' -f $mbx, $a) `
                -Message 'Skipped - alias already in the requested state (idempotent)'
            continue
        }

        if ($Operation -eq 'Add') {
            $domain = ($a -split '@')[-1]
            if ($acceptedDomains -notcontains $domain) {
                throw ('Refusing to add {0} - {1} is not an accepted domain in this tenant.' -f $a, $domain)
            }
        }

        $results.Add([PSCustomObject]@{
            Name           = ('{0} : {1} {2}' -f $mb.PrimarySmtpAddress, $Operation, $a)
            Id             = $mb.Identity
            Mailbox        = $mb.PrimarySmtpAddress
            Alias          = $a
            Operation      = $Operation
            CurrentAddresses = ($current -join '; ')
            AddressCount   = $current.Count
        })
    }
}
""",
    act="""
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Prior addresses ({0}): {1}' -f $item.AddressCount, $item.CurrentAddresses)

if ($item.Operation -eq 'Add') {
    Set-Mailbox -Identity $item.Id -EmailAddresses @{ Add = $item.Alias } -ErrorAction Stop
    $detail = 'alias {0} added' -f $item.Alias
} else {
    Set-Mailbox -Identity $item.Id -EmailAddresses @{ Remove = $item.Alias } -ErrorAction Stop
    $detail = 'alias {0} removed' -f $item.Alias
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message $detail
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
"""),

23: dict(
    file='Set-EntraUserMfaState',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.SignIns'],
    synopsis='Enables or disables per-user MFA state for an Entra ID account.',
    desc='Changes a user\'s per-user MFA requirement. Disabling MFA removes a security control and '
         'is a standard objective for an attacker who has already obtained a password, so it '
         'requires approval, a ticket reference, and - for disable - an explicit acknowledgement '
         'that identity was verified out of band.',
    params=[dict(name='UserPrincipalName', help='User(s) to change.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$UserPrincipalName"),
            dict(name='Operation', help='Enable or Disable per-user MFA.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Enable','Disable')]\n    [string]$Operation"),
            dict(name='IdentityVerifiedOutOfBand', help='Confirms the requester was verified through a channel other than email. Required to disable.',
                 decl="[switch]$IdentityVerifiedOutOfBand")],
    perms='Microsoft Graph Policy.ReadWrite.AuthenticationMethod and UserAuthenticationMethod.ReadWrite.All.',
    actionVerb='Change MFA state',
    reason='Per-user MFA state change',
    rollback='Re-run with the opposite -Operation. A disabled MFA state should be re-enabled as '
             'soon as the reason for disabling it has passed.',
    notes='Per-user MFA is legacy. Conditional Access is the supported mechanism and takes '
          'precedence. Disabling per-user MFA does NOT bypass a Conditional Access policy that '
          'requires MFA - if the user still cannot sign in afterwards, that is why.',
    examples=[("-UserPrincipalName user@contoso.com -Operation Disable -TicketReference INC0012345 -IdentityVerifiedOutOfBand",
               'REQUEST mode - raises an approval to disable MFA.'),
              ("-UserPrincipalName user@contoso.com -Operation Enable -ApprovalReference APR-...",
               'Re-enables MFA for the user.')],
    discover=GRAPH.format("User.Read.All','UserAuthenticationMethod.ReadWrite.All") + """
if (-not $TicketReference) {
    throw 'A -TicketReference is required for any MFA change.'
}
if ($Operation -eq 'Disable' -and -not $IdentityVerifiedOutOfBand) {
    throw 'Refusing to disable MFA without -IdentityVerifiedOutOfBand. Verify the requester by phone ' +
          'or in person first - an emailed request is exactly what an attacker with mailbox access sends.'
}

foreach ($upn in $UserPrincipalName) {
    $u = Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName,AccountEnabled -ErrorAction Stop

    $methods = @()
    try {
        $methods = @(Get-MgUserAuthenticationMethod -UserId $u.Id -ErrorAction Stop |
                     ForEach-Object { ($_.AdditionalProperties.'@odata.type' -replace '#microsoft.graph.', '') })
    } catch {
        Write-Verbose ('Could not read authentication methods for {0}' -f $upn)
    }

    $results.Add([PSCustomObject]@{
        Name            = $u.UserPrincipalName
        Id              = $u.Id
        DisplayName     = $u.DisplayName
        AccountEnabled  = $u.AccountEnabled
        Operation       = $Operation
        RegisteredMethods = ($methods -join '; ')
        MethodCount     = $methods.Count
        Ticket          = $TicketReference
        VerifiedOutOfBand = [bool]$IdentityVerifiedOutOfBand
        SecurityNote    = if ($Operation -eq 'Disable') { 'REMOVES a security control - re-enable as soon as possible' }
                          else { 'Restores the security control' }
        CaCaveat        = 'Conditional Access policies take precedence over per-user MFA state'
    })
}
""",
    act="""
$state = if ($item.Operation -eq 'Enable') { 'enabled' } else { 'disabled' }

if ($item.Operation -eq 'Disable') {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
        'DISABLING MFA. Ticket={0} Approval={1} OutOfBandVerified={2}' -f
        $TicketReference, $ApprovalReference, $item.VerifiedOutOfBand)
}

$body = @{ perUserMfaState = $state }
Invoke-MgGraphRequest -Method PATCH `
    -Uri ('https://graph.microsoft.com/beta/users/{0}/authentication/requirements' -f $item.Id) `
    -Body ($body | ConvertTo-Json) -ErrorAction Stop | Out-Null

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Per-user MFA state set to {0}. Conditional Access still applies independently.' -f $state)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Operation; Detail = ('perUserMfaState={0}' -f $state); Succeeded = $true })
"""),

24: dict(
    file='Reset-EntraUserMfaMethod',
    modules=['Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.SignIns'],
    synopsis='Clears a user\'s registered MFA methods so they can re-enrol.',
    desc='Removes registered authentication methods, forcing re-registration at next sign-in. This '
         'is the single most attractive help-desk request for a social engineer: an attacker with '
         'a password calls claiming to have lost their phone. The script therefore requires '
         'approval, a ticket, and explicit out-of-band verification.',
    params=[dict(name='UserPrincipalName', help='User whose methods to clear.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$UserPrincipalName"),
            dict(name='IdentityVerifiedOutOfBand', help='Confirms the requester was verified through a channel other than email or chat. Mandatory.',
                 decl="[switch]$IdentityVerifiedOutOfBand"),
            dict(name='MethodType', help='Method types to remove. Defaults to phone and authenticator.',
                 decl="[ValidateSet('phone','microsoftAuthenticator','softwareOath','fido2','windowsHelloForBusiness','all')]\n    [string[]]$MethodType = @('phone','microsoftAuthenticator')")],
    perms='Microsoft Graph UserAuthenticationMethod.ReadWrite.All.',
    actionVerb='Reset MFA methods',
    reason='MFA method reset (out-of-band verified)',
    rollback='NONE - a removed method cannot be restored. The user must re-register. That is the '
             'intended outcome, but it also means a fraudulent reset hands the account to whoever '
             're-registers first.',
    notes='Verify the requester through a channel the attacker does not control. A call to the '
          'number already on record, or an in-person check, is the standard. Email and chat are NOT '
          'out-of-band if the account may already be compromised.',
    examples=[("-UserPrincipalName user@contoso.com -TicketReference INC0012345 -IdentityVerifiedOutOfBand",
               'REQUEST mode - raises an approval for the reset.'),
              ("-UserPrincipalName user@contoso.com -TicketReference INC0012345 -IdentityVerifiedOutOfBand -ApprovalReference APR-...",
               'Performs the approved reset.')],
    discover=GRAPH.format("User.Read.All','UserAuthenticationMethod.ReadWrite.All") + """
if (-not $TicketReference) {
    throw 'A -TicketReference is required for an MFA reset.'
}
if (-not $IdentityVerifiedOutOfBand) {
    throw 'Refusing without -IdentityVerifiedOutOfBand. An MFA reset is the prime social-engineering ' +
          'target: verify the requester by a channel an attacker could not control before proceeding.'
}

foreach ($upn in $UserPrincipalName) {
    $u = Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName -ErrorAction Stop

    $methods = @(Get-MgUserAuthenticationMethod -UserId $u.Id -ErrorAction Stop)
    $targets = @()
    foreach ($m in $methods) {
        $type = ($m.AdditionalProperties.'@odata.type' -replace '#microsoft.graph.', '') -replace 'AuthenticationMethod$', ''
        if ($MethodType -contains 'all' -or $MethodType -contains $type) {
            $targets += [PSCustomObject]@{ Id = $m.Id; Type = $type }
        }
    }

    if ($targets.Count -eq 0) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $upn `
            -Message 'Skipped - no matching methods registered'
        continue
    }

    $results.Add([PSCustomObject]@{
        Name            = $u.UserPrincipalName
        Id              = $u.Id
        DisplayName     = $u.DisplayName
        MethodsToRemove = (($targets | ForEach-Object { $_.Type }) -join '; ')
        MethodCount     = $targets.Count
        MethodDetail    = $targets
        Ticket          = $TicketReference
        VerifiedOutOfBand = $true
        RiskNote        = 'After reset the first person to re-register controls the account'
    })
}
""",
    act="""
Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
    'Resetting {0} MFA method(s). Ticket={1} Approval={2} OutOfBandVerified=true' -f
    $item.MethodCount, $TicketReference, $ApprovalReference)

$removed = 0
foreach ($m in $item.MethodDetail) {
    try {
        $uri = 'https://graph.microsoft.com/v1.0/users/{0}/authentication/{1}Methods/{2}' -f
               $item.Id, $m.Type, $m.Id
        Invoke-MgGraphRequest -Method DELETE -Uri $uri -ErrorAction Stop | Out-Null
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
            'Removed method: {0}' -f $m.Type)
        $removed++
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label -Message (
            'Could not remove {0}: {1}' -f $m.Type, $_.Exception.Message)
    }
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} of {1} method(s) removed. User must re-register at next sign-in.' -f $removed, $item.MethodCount)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'MfaReset'
    Detail = ('{0}/{1} methods removed' -f $removed, $item.MethodCount)
    Succeeded = ($removed -eq $item.MethodCount) })
"""),

25: dict(
    file='Set-ExoMobileDeviceAccess',
    modules=['ExchangeOnlineManagement'],
    synopsis='Blocks or allows a mobile device\'s access to a mailbox.',
    desc='Changes the ActiveSync access state for a specific device. Blocking a device cuts mail '
         'access from it immediately, which is what you want for a lost handset and disruptive if '
         'the device id is wrong - so the script reports the device\'s identity and last sync time '
         'before the change is approved.',
    params=[dict(name='Mailbox', help='Mailbox owning the device.',
                 decl="[Parameter(Mandatory)]\n    [string]$Mailbox"),
            dict(name='Operation', help='Block or Allow.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Block','Allow')]\n    [string]$Operation"),
            dict(name='DeviceId', help='Specific device id(s). All devices for the mailbox when omitted.',
                 decl="[string[]]$DeviceId"),
            dict(name='StaleDays', help='When -DeviceId is omitted, only act on devices that have not synced for this long.',
                 decl="[ValidateRange(0,3650)]\n    [int]$StaleDays = 0")],
    perms='Exchange Online Recipient Management.',
    actionVerb='Change device access state',
    reason='Mobile device access change',
    rollback='Re-run with the opposite -Operation. Blocking is immediately reversible; note that a '
             'wiped device is not, and this script never wipes.',
    notes='This changes ACCESS only. It does not wipe the device and does not remove company data '
          'already on it. For a lost device where data removal is required, use an Intune wipe as a '
          'separate, deliberate action.',
    examples=[("-Mailbox user@contoso.com -Operation Block -DeviceId ABC123 -TicketReference INC0012345",
               'REQUEST mode - raises an approval to block one device.'),
              ("-Mailbox user@contoso.com -Operation Block -StaleDays 90 -ApprovalReference APR-...",
               'Blocks devices that have not synced in 90 days.')],
    discover=CONNECT + """
$mb = Get-Mailbox -Identity $Mailbox -ErrorAction Stop
$devices = @(Get-MobileDevice -Mailbox $mb.Identity -ErrorAction SilentlyContinue)

if ($devices.Count -eq 0) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $Mailbox -Message 'No mobile devices registered'
    return
}

foreach ($dev in $devices) {
    if ($DeviceId -and $DeviceId -notcontains $dev.DeviceId) { continue }

    $stats = $null
    try { $stats = Get-MobileDeviceStatistics -Identity $dev.Identity -ErrorAction Stop } catch {
        Write-Verbose ('No statistics for device {0}' -f $dev.DeviceId)
    }
    $lastSync = if ($stats) { $stats.LastSuccessSync } else { $null }
    $staleDaysActual = if ($lastSync) { [math]::Round(((Get-Date) - $lastSync).TotalDays, 1) } else { $null }

    # When selecting by staleness rather than by id, skip anything recently used.
    if (-not $DeviceId -and $StaleDays -gt 0) {
        if ($null -eq $staleDaysActual -or $staleDaysActual -lt $StaleDays) { continue }
    }

    $wanted = if ($Operation -eq 'Block') { 'Blocked' } else { 'Allowed' }
    if ("$($dev.DeviceAccessState)" -eq $wanted) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $dev.DeviceId `
            -Message ('Skipped - already {0} (idempotent)' -f $wanted)
        continue
    }

    $results.Add([PSCustomObject]@{
        Name            = ('{0} : {1} {2}' -f $mb.PrimarySmtpAddress, $dev.DeviceModel, $dev.DeviceId)
        Id              = $dev.Identity
        Mailbox         = $mb.PrimarySmtpAddress
        DeviceId        = $dev.DeviceId
        DeviceModel     = $dev.DeviceModel
        DeviceOS        = $dev.DeviceOS
        DeviceUserAgent = $dev.DeviceUserAgent
        FirstSync       = $dev.FirstSyncTime
        LastSuccessSync = $lastSync
        StaleDays       = $staleDaysActual
        CurrentState    = "$($dev.DeviceAccessState)"
        DesiredState    = $wanted
        Operation       = $Operation
        Scope           = 'Access only - this does NOT wipe the device'
    })
}
""",
    act="""
$accessState = if ($item.Operation -eq 'Block') { 'Block' } else { 'Allow' }

Set-CASMailbox -Identity $item.Mailbox `
    -ActiveSyncBlockedDeviceIDs @{ $(if ($item.Operation -eq 'Block') { 'Add' } else { 'Remove' }) = $item.DeviceId } `
    -ErrorAction Stop

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Device {0} ({1}) set to {2}. Last sync {3}. Access only - device NOT wiped. Ticket={4}' -f
    $item.DeviceId, $item.DeviceModel, $accessState, $item.LastSuccessSync, $TicketReference)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Operation
    Detail = ('{0} -> {1}' -f $item.CurrentState, $item.DesiredState); Succeeded = $true })
"""),
}
