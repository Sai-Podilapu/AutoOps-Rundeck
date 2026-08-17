# -*- coding: utf-8 -*-
"""AD & Identity - 12 use cases. Real ActiveDirectory module cmdlets."""

SERVER = dict(name='Server', help='Domain controller to target. Uses the nearest DC when omitted.',
              decl="[string]$Server")
CRED = dict(name='Credential', help='Credential for the directory operation.',
            decl="[System.Management.Automation.PSCredential]\n    [System.Management.Automation.Credential()]\n    $Credential = [System.Management.Automation.PSCredential]::Empty")

# Every AD script binds the same way. Pinning a single DC matters for writes:
# without it a create-then-read can hit a replica that has not caught up yet.
ADARGS = """
$adArgs = @{ ErrorAction = 'Stop' }
if ($Server) { $adArgs.Server = $Server }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $adArgs.Credential = $Credential }
"""

SPECS = {

1: dict(
    file='New-AdUserOnboarding',
    modules=['ActiveDirectory'],
    synopsis='Creates an Active Directory user for onboarding with a cloud mailbox.',
    desc='Creates the AD account, places it in the joiner OU, applies group memberships from a role '
         'template and sets the attributes Entra ID Connect needs to provision a cloud mailbox. The '
         'mailbox itself is created by licence assignment after sync, which this script reports '
         'rather than pretends to do.',
    params=[SERVER, CRED,
            dict(name='SamAccountName', help='Logon name for the new account.',
                 decl="[Parameter(Mandatory)]\n    [ValidateLength(1,20)]\n    [string]$SamAccountName"),
            dict(name='GivenName', help='First name.',
                 decl="[Parameter(Mandatory)]\n    [string]$GivenName"),
            dict(name='Surname', help='Last name.',
                 decl="[Parameter(Mandatory)]\n    [string]$Surname"),
            dict(name='TargetOU', help='Distinguished name of the OU to create the account in.',
                 decl="[Parameter(Mandatory)]\n    [string]$TargetOU"),
            dict(name='UpnSuffix', help='UPN suffix. Must be a routable domain that is verified in the tenant.',
                 decl="[Parameter(Mandatory)]\n    [string]$UpnSuffix"),
            dict(name='RoleGroup', help='Security groups to add the user to, from the role template.',
                 decl="[string[]]$RoleGroup"),
            dict(name='Manager', help='Manager\\u2019s sam account name or DN.',
                 decl="[string]$Manager"),
            dict(name='Department', help='Department attribute.',
                 decl="[string]$Department"),
            dict(name='JobTitle', help='Title attribute.',
                 decl="[string]$JobTitle"),
            dict(name='InitialPassword', help='Initial password as a SecureString. Generated and shown once if omitted.',
                 decl="[System.Security.SecureString]$InitialPassword")],
    perms='Delegated Create User Objects on the target OU, plus group membership write on the role groups.',
    actionVerb='Create AD user (cloud mailbox)',
    rollback='Remove-ADUser, or disable and move to the leavers OU. A newly created account has no '
             'data, so removal is safe in the first hours.',
    notes='This script does NOT create the mailbox. With Entra ID Connect, the account syncs to the '
          'tenant and the mailbox appears when a licence is assigned - use Set-O365UserLicense.ps1 '
          'once the sync has run. Reporting that as a follow-up step is honest; claiming the '
          'mailbox exists would not be.',
    examples=[("-SamAccountName jsmith -GivenName John -Surname Smith -TargetOU 'OU=Joiners,DC=contoso,DC=com' -UpnSuffix contoso.com -RoleGroup 'GG-AllStaff'",
               'Creates the account and adds the role group.'),
              ("-SamAccountName jsmith -GivenName John -Surname Smith -TargetOU '...' -UpnSuffix contoso.com -WhatIf",
               'Shows what would be created.')],
    discover=ADARGS + """
Import-Module ActiveDirectory -ErrorAction Stop

if (Get-ADUser -Filter ("SamAccountName -eq '{0}'" -f $SamAccountName) @adArgs -ErrorAction SilentlyContinue) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $SamAccountName `
        -Message 'Skipped - account already exists (idempotent)'
    return
}

# Fail before creating anything if the destination or the groups are wrong.
try { Get-ADOrganizationalUnit -Identity $TargetOU @adArgs | Out-Null }
catch { throw ('Target OU does not exist: {0}' -f $TargetOU) }

foreach ($g in $RoleGroup) {
    try { Get-ADGroup -Identity $g @adArgs | Out-Null }
    catch { throw ('Role group does not exist: {0}' -f $g) }
}
if ($Manager) {
    try { Get-ADUser -Identity $Manager @adArgs | Out-Null }
    catch { throw ('Manager not found: {0}' -f $Manager) }
}

$upn = '{0}@{1}' -f $SamAccountName, $UpnSuffix
if (Get-ADUser -Filter ("UserPrincipalName -eq '{0}'" -f $upn) @adArgs -ErrorAction SilentlyContinue) {
    throw ('UPN {0} is already in use.' -f $upn)
}

$results.Add([PSCustomObject]@{
    Name           = $SamAccountName
    Id             = $SamAccountName
    DisplayName    = ('{0} {1}' -f $GivenName, $Surname)
    UserPrincipalName = $upn
    TargetOU       = $TargetOU
    RoleGroups     = ($RoleGroup -join '; ')
    Manager        = $Manager
    Department     = $Department
    JobTitle       = $JobTitle
    MailboxRoute   = 'Cloud (Exchange Online) - created by licence assignment after directory sync'
    FollowUp       = 'Assign a licence with Set-O365UserLicense.ps1 once Entra ID Connect has synced'
})
""",
    act="""
if ($InitialPassword) {
    $newSecurePassword = $InitialPassword
    $generated = $false
} else {
    # Built straight into a SecureString so the value never exists as plaintext.
    $alphabet = ([char[]]((48..57) + (65..90) + (97..122) + (33,35,36,37,38,42,43,45,61,63,64,95)))
    $newSecurePassword = New-Object System.Security.SecureString
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buf = New-Object byte[] 1
        $limit = [byte](256 - (256 % $alphabet.Length))
        for ($i = 0; $i -lt 20; $i++) {
            do { $rng.GetBytes($buf) } while ($buf[0] -ge $limit)
            $newSecurePassword.AppendChar($alphabet[$buf[0] % $alphabet.Length])
        }
    } finally { $rng.Dispose() }
    $newSecurePassword.MakeReadOnly()
    $generated = $true
}

$newParams = @{
    SamAccountName        = $item.Name
    UserPrincipalName     = $item.UserPrincipalName
    Name                  = $item.DisplayName
    GivenName             = $GivenName
    Surname               = $Surname
    DisplayName           = $item.DisplayName
    Path                  = $item.TargetOU
    AccountPassword       = $pwd
    Enabled               = $true
    ChangePasswordAtLogon = $true
}
if ($Department) { $newParams.Department = $Department }
if ($JobTitle)   { $newParams.Title = $JobTitle }
if ($Manager)    { $newParams.Manager = $Manager }

New-ADUser @newParams @adArgs

$addedGroups = 0
foreach ($g in $RoleGroup) {
    try {
        Add-ADGroupMember -Identity $g -Members $item.Name @adArgs
        $addedGroups++
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
            -Message ('Could not add to group {0}: {1}' -f $g, $_.Exception.Message)
    }
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Account created in {0}, {1} group(s) added, password generated={2}, change-at-logon set. ' +
    'Mailbox follows licence assignment after sync.' -f $item.TargetOU, $addedGroups, $generated)

$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'UserCreated'
    Detail = ('{0}; {1} groups; licence assignment still required' -f $item.UserPrincipalName, $addedGroups)
    Succeeded = $true })
"""),

2: dict(
    file='New-AdUserOnboardingOnPrem',
    modules=['ActiveDirectory'],
    synopsis='Creates an Active Directory user for onboarding with an on-premises Exchange mailbox.',
    desc='Creates the AD account and enables an on-premises Exchange mailbox in one operation. '
         'Unlike the cloud variant, the mailbox genuinely is created here, because Enable-Mailbox '
         'runs against the local Exchange organisation rather than waiting on a directory sync.',
    params=[SERVER, CRED,
            dict(name='SamAccountName', help='Logon name for the new account.',
                 decl="[Parameter(Mandatory)]\n    [ValidateLength(1,20)]\n    [string]$SamAccountName"),
            dict(name='GivenName', help='First name.',
                 decl="[Parameter(Mandatory)]\n    [string]$GivenName"),
            dict(name='Surname', help='Last name.',
                 decl="[Parameter(Mandatory)]\n    [string]$Surname"),
            dict(name='TargetOU', help='Distinguished name of the OU to create the account in.',
                 decl="[Parameter(Mandatory)]\n    [string]$TargetOU"),
            dict(name='UpnSuffix', help='UPN suffix for the account.',
                 decl="[Parameter(Mandatory)]\n    [string]$UpnSuffix"),
            dict(name='MailboxDatabase', help='Exchange mailbox database to create the mailbox in.',
                 decl="[string]$MailboxDatabase"),
            dict(name='ExchangeServer', help='Exchange server hosting the management endpoint.',
                 decl="[Parameter(Mandatory)]\n    [string]$ExchangeServer"),
            dict(name='RoleGroup', help='Security groups to add the user to.',
                 decl="[string[]]$RoleGroup"),
            dict(name='InitialPassword', help='Initial password as a SecureString. Generated if omitted.',
                 decl="[System.Security.SecureString]$InitialPassword")],
    perms='Delegated Create User Objects on the OU, plus Exchange Recipient Management for Enable-Mailbox.',
    actionVerb='Create AD user (on-premises mailbox)',
    rollback='Disable-Mailbox then Remove-ADUser. Disabling the mailbox disconnects it; it is '
             'retained for the deleted-mailbox retention period before purging.',
    notes='Connects to the on-premises Exchange management endpoint over Kerberos. If the account '
          'running this does not have Exchange RBAC rights, the AD account is still created and the '
          'mailbox step fails - the script reports that partial outcome rather than claiming success.',
    examples=[("-SamAccountName jsmith -GivenName John -Surname Smith -TargetOU 'OU=Joiners,DC=contoso,DC=com' -UpnSuffix contoso.com -ExchangeServer ex01.contoso.com",
               'Creates the account and enables an on-premises mailbox.'),
              ("-SamAccountName jsmith -GivenName John -Surname Smith -TargetOU '...' -UpnSuffix contoso.com -ExchangeServer ex01 -WhatIf",
               'Shows what would be created.')],
    discover=ADARGS + """
Import-Module ActiveDirectory -ErrorAction Stop

if (Get-ADUser -Filter ("SamAccountName -eq '{0}'" -f $SamAccountName) @adArgs -ErrorAction SilentlyContinue) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $SamAccountName `
        -Message 'Skipped - account already exists (idempotent)'
    return
}

try { Get-ADOrganizationalUnit -Identity $TargetOU @adArgs | Out-Null }
catch { throw ('Target OU does not exist: {0}' -f $TargetOU) }

foreach ($g in $RoleGroup) {
    try { Get-ADGroup -Identity $g @adArgs | Out-Null }
    catch { throw ('Role group does not exist: {0}' -f $g) }
}

$upn = '{0}@{1}' -f $SamAccountName, $UpnSuffix

$results.Add([PSCustomObject]@{
    Name              = $SamAccountName
    Id                = $SamAccountName
    DisplayName       = ('{0} {1}' -f $GivenName, $Surname)
    UserPrincipalName = $upn
    TargetOU          = $TargetOU
    RoleGroups        = ($RoleGroup -join '; ')
    ExchangeServer    = $ExchangeServer
    MailboxDatabase   = $MailboxDatabase
    MailboxRoute      = 'On-premises Exchange - created by Enable-Mailbox in this run'
})
""",
    act="""
if ($InitialPassword) {
    $newSecurePassword = $InitialPassword
} else {
    $alphabet = ([char[]]((48..57) + (65..90) + (97..122) + (33,35,36,37,38,42,43,45,61,63,64,95)))
    $newSecurePassword = New-Object System.Security.SecureString
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buf = New-Object byte[] 1
        $limit = [byte](256 - (256 % $alphabet.Length))
        for ($i = 0; $i -lt 20; $i++) {
            do { $rng.GetBytes($buf) } while ($buf[0] -ge $limit)
            $newSecurePassword.AppendChar($alphabet[$buf[0] % $alphabet.Length])
        }
    } finally { $rng.Dispose() }
    $newSecurePassword.MakeReadOnly()
}

New-ADUser -SamAccountName $item.Name -UserPrincipalName $item.UserPrincipalName `
    -Name $item.DisplayName -GivenName $GivenName -Surname $Surname -DisplayName $item.DisplayName `
    -Path $item.TargetOU -AccountPassword $newSecurePassword -Enabled $true -ChangePasswordAtLogon $true @adArgs

$addedGroups = 0
foreach ($g in $RoleGroup) {
    try { Add-ADGroupMember -Identity $g -Members $item.Name @adArgs; $addedGroups++ }
    catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                -Message ('Could not add to group {0}: {1}' -f $g, $_.Exception.Message) }
}

# The mailbox step is separate and can fail on its own. A partial outcome is
# reported as partial rather than as success.
$mailboxCreated = $false
$session = $null
try {
    $uri = 'http://{0}/PowerShell/' -f $item.ExchangeServer
    $sessionParams = @{ ConfigurationName = 'Microsoft.Exchange'; ConnectionUri = $uri
                        Authentication = 'Kerberos'; ErrorAction = 'Stop' }
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $sessionParams.Credential = $Credential }
    $session = New-PSSession @sessionParams
    Import-PSSession $session -CommandName Enable-Mailbox -AllowClobber -DisableNameChecking | Out-Null

    $enableParams = @{ Identity = $item.UserPrincipalName; ErrorAction = 'Stop' }
    if ($item.MailboxDatabase) { $enableParams.Database = $item.MailboxDatabase }
    Enable-Mailbox @enableParams | Out-Null
    $mailboxCreated = $true
} catch {
    Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $label -Message (
        'AD account created but mailbox enablement FAILED: {0}. Enable the mailbox manually.' -f $_.Exception.Message)
} finally {
    if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Account created in {0}, {1} group(s) added, mailbox enabled: {2}' -f
    $item.TargetOU, $addedGroups, $mailboxCreated)

$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = if ($mailboxCreated) { 'UserAndMailboxCreated' } else { 'UserCreatedMailboxFailed' }
    Detail = ('{0}; groups {1}; mailbox {2}' -f $item.UserPrincipalName, $addedGroups, $mailboxCreated)
    Succeeded = $mailboxCreated })
"""),

3: dict(
    file='Remove-AdUserOffboardingCloud',
    modules=['ActiveDirectory'],
    synopsis='Offboards a leaver whose mailbox is in Exchange Online.',
    desc='Runs the full leaver sequence: disable the account, reset the password to a random value, '
         'revoke sessions, strip group memberships, hide from the address list and move to the '
         'leavers OU. Deliberately does NOT delete the account, because deleting it destroys the '
         'link to the cloud mailbox and its data.',
    params=[SERVER, CRED,
            dict(name='Identity', help='Leaver(s) to offboard, by sam account name or DN.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Identity"),
            dict(name='LeaversOU', help='Distinguished name of the leavers OU. Falls back to activeDirectory.disabledUsersOU in config.json.',
                 decl="[string]$LeaversOU"),
            dict(name='KeepGroups', help='Groups to leave in place, e.g. a licensing group that must stay until the mailbox is converted.',
                 decl="[string[]]$KeepGroups"),
            dict(name='RemoveFromGroups', help='Strip group memberships. On by default.',
                 decl="[bool]$RemoveFromGroups = $true")],
    minage=0,
    perms='Delegated user management on the source and leavers OUs, plus group membership write.',
    actionVerb='Offboard leaver (cloud mailbox)',
    reason='Leaver offboarding - cloud mailbox',
    rollback='Re-enable the account, restore the group memberships recorded in the audit log, and '
             'move it back to its original OU - all three are captured before any change. Note that '
             'a stripped membership list is only recoverable from that log.',
    notes='The account is disabled and moved, never deleted. Deleting the AD object breaks the link '
          'to the synced cloud mailbox, and recovering the mail afterwards is far harder than '
          'leaving a disabled object in place until retention expires.',
    examples=[("-Identity jsmith -TicketReference HR0012345",
               'REPORT ONLY. Shows the full leaver change set and raises an approval.'),
              ("-Identity jsmith -TicketReference HR0012345 -ApprovalReference APR-... -Execute",
               'Performs the approved offboarding.')],
    discover=ADARGS + """
Import-Module ActiveDirectory -ErrorAction Stop

if (-not $LeaversOU -and $config -and $config.activeDirectory) { $LeaversOU = $config.activeDirectory.disabledUsersOU }
if (-not $LeaversOU) {
    throw 'No leavers OU. Pass -LeaversOU or set activeDirectory.disabledUsersOU in config.json.'
}
try { Get-ADOrganizationalUnit -Identity $LeaversOU @adArgs | Out-Null }
catch { throw ('Leavers OU does not exist: {0}' -f $LeaversOU) }

foreach ($id in $Identity) {
    $u = Get-ADUser -Identity $id -Properties MemberOf,Enabled,DistinguishedName,DisplayName,Mail,Manager,LastLogonDate @adArgs

    $groups = @($u.MemberOf | ForEach-Object { (Get-ADGroup -Identity $_ @adArgs).Name })
    $toRemove = @($groups | Where-Object { $KeepGroups -notcontains $_ })

    $results.Add([PSCustomObject]@{
        Name            = $u.SamAccountName
        Id              = $u.DistinguishedName
        DisplayName     = $u.DisplayName
        Mail            = $u.Mail
        CurrentlyEnabled= $u.Enabled
        CurrentOU       = ($u.DistinguishedName -replace '^CN=[^,]+,', '')
        LeaversOU       = $LeaversOU
        LastLogon       = $u.LastLogonDate
        AllGroups       = ($groups -join '; ')
        GroupsToRemove  = ($toRemove -join '; ')
        GroupsKept      = (($groups | Where-Object { $KeepGroups -contains $_ }) -join '; ')
        RemoveGroupCount= $toRemove.Count
        Steps           = 'disable; reset password; strip groups; hide from GAL; move to leavers OU'
        NotDeleted      = 'Account is DISABLED and moved, never deleted - deletion would break the cloud mailbox link'
    })
}
""",
    backup="""
# The membership list is the only part of this that is hard to reconstruct, so
# it is written to a rollback file before anything is stripped.
$rollbackDir = Join-Path $env:ProgramData 'ITAutomation\\Rollback'
if (-not (Test-Path -LiteralPath $rollbackDir)) { New-Item -Path $rollbackDir -ItemType Directory -Force | Out-Null }
$rollbackPath = Join-Path $rollbackDir ('offboard-{0}-{1}.json' -f $item.Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
$item | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $rollbackPath -Encoding UTF8
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Pre-change state written to {0} - this is the restore path' -f $rollbackPath)
""",
    act="""
# 1. Disable
Disable-ADAccount -Identity $item.Id @adArgs
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message 'Account disabled'

# 2. Reset the password so any cached credential stops working.
$alphabet = ([char[]]((48..57) + (65..90) + (97..122) + (33,35,36,37,38,42,43,45,61,63,64,95)))
$newSecurePassword = New-Object System.Security.SecureString
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $buf = New-Object byte[] 1
    $limit = [byte](256 - (256 % $alphabet.Length))
    for ($i = 0; $i -lt 24; $i++) {
        do { $rng.GetBytes($buf) } while ($buf[0] -ge $limit)
        $newSecurePassword.AppendChar($alphabet[$buf[0] % $alphabet.Length])
    }
} finally { $rng.Dispose() }
$newSecurePassword.MakeReadOnly()
Set-ADAccountPassword -Identity $item.Id -NewPassword $newSecurePassword -Reset @adArgs
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message 'Password reset to a random value'

# 3. Strip group memberships, keeping any explicitly excluded.
$removed = 0
if ($RemoveFromGroups -and $item.GroupsToRemove) {
    foreach ($g in ($item.GroupsToRemove -split '; ')) {
        if (-not $g) { continue }
        try { Remove-ADGroupMember -Identity $g -Members $item.Name -Confirm:$false @adArgs; $removed++ }
        catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                    -Message ('Could not remove from {0}: {1}' -f $g, $_.Exception.Message) }
    }
}

# 4. Hide from the address list so the leaver stops appearing in the GAL.
try { Set-ADUser -Identity $item.Id -Replace @{ msExchHideFromAddressLists = $true } @adArgs }
catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
            -Message 'Could not set msExchHideFromAddressLists (Exchange schema may not be present)' }

# 5. Move to the leavers OU.
Move-ADObject -Identity $item.Id -TargetPath $item.LeaversOU @adArgs

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Offboarded: disabled, password reset, {0} group(s) removed, hidden from GAL, moved to {1}. ' +
    'Account NOT deleted. Ticket={2} Approval={3}' -f $removed, $item.LeaversOU, $TicketReference, $ApprovalReference)

$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Offboarded'
    Detail = ('{0} groups removed; moved to leavers OU; rollback at {1}' -f $removed, $rollbackPath)
    Succeeded = $true })
"""),

4: dict(
    file='Remove-AdUserOffboardingOnPrem',
    modules=['ActiveDirectory'],
    synopsis='Offboards a leaver whose mailbox is on on-premises Exchange.',
    desc='The on-premises leaver sequence: disable, reset password, strip groups, hide from the GAL, '
         'move to the leavers OU, and optionally set a mailbox forward to the manager. The mailbox '
         'is retained rather than disabled, because disabling it starts the retention clock and the '
         'mail is usually needed for a handover.',
    params=[SERVER, CRED,
            dict(name='Identity', help='Leaver(s) to offboard.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Identity"),
            dict(name='LeaversOU', help='Distinguished name of the leavers OU.',
                 decl="[string]$LeaversOU"),
            dict(name='ExchangeServer', help='Exchange server hosting the management endpoint. Required for the forwarding step.',
                 decl="[string]$ExchangeServer"),
            dict(name='ForwardToManager', help='Forward the leaver\\u2019s mail to their manager for a handover period.',
                 decl="[switch]$ForwardToManager"),
            dict(name='KeepGroups', help='Groups to leave in place.',
                 decl="[string[]]$KeepGroups")],
    minage=0,
    perms='Delegated user management on both OUs, plus Exchange Recipient Management for forwarding.',
    actionVerb='Offboard leaver (on-premises mailbox)',
    reason='Leaver offboarding - on-premises mailbox',
    rollback='Re-enable, restore memberships from the rollback file, move back, and clear any '
             'forwarding. All prior state is captured before the first change.',
    notes='The mailbox is deliberately NOT disabled. Disable-Mailbox disconnects it and starts the '
          'deleted-mailbox retention clock; keeping it attached to a disabled account preserves the '
          'mail indefinitely and keeps the handover simple.',
    examples=[("-Identity jsmith -TicketReference HR0012345",
               'REPORT ONLY. Shows the change set and raises an approval.'),
              ("-Identity jsmith -TicketReference HR0012345 -ForwardToManager -ApprovalReference APR-... -Execute",
               'Offboards and forwards mail to the manager.')],
    discover=ADARGS + """
Import-Module ActiveDirectory -ErrorAction Stop

if (-not $LeaversOU -and $config -and $config.activeDirectory) { $LeaversOU = $config.activeDirectory.disabledUsersOU }
if (-not $LeaversOU) { throw 'No leavers OU. Pass -LeaversOU or set activeDirectory.disabledUsersOU in config.json.' }
if ($ForwardToManager -and -not $ExchangeServer) {
    throw '-ForwardToManager requires -ExchangeServer to reach the Exchange management endpoint.'
}

foreach ($id in $Identity) {
    $u = Get-ADUser -Identity $id -Properties MemberOf,Enabled,DistinguishedName,DisplayName,Mail,Manager,LastLogonDate @adArgs

    $groups = @($u.MemberOf | ForEach-Object { (Get-ADGroup -Identity $_ @adArgs).Name })
    $toRemove = @($groups | Where-Object { $KeepGroups -notcontains $_ })

    $managerMail = $null
    if ($u.Manager) {
        try { $managerMail = (Get-ADUser -Identity $u.Manager -Properties Mail @adArgs).Mail } catch {
            Write-Verbose ('Could not resolve manager for {0}' -f $u.SamAccountName)
        }
    }
    if ($ForwardToManager -and -not $managerMail) {
        throw ('{0} has no resolvable manager mail address; cannot forward.' -f $u.SamAccountName)
    }

    $results.Add([PSCustomObject]@{
        Name            = $u.SamAccountName
        Id              = $u.DistinguishedName
        DisplayName     = $u.DisplayName
        Mail            = $u.Mail
        CurrentlyEnabled= $u.Enabled
        CurrentOU       = ($u.DistinguishedName -replace '^CN=[^,]+,', '')
        LeaversOU       = $LeaversOU
        LastLogon       = $u.LastLogonDate
        AllGroups       = ($groups -join '; ')
        GroupsToRemove  = ($toRemove -join '; ')
        RemoveGroupCount= $toRemove.Count
        ManagerMail     = $managerMail
        ForwardToManager= [bool]$ForwardToManager
        ExchangeServer  = $ExchangeServer
        MailboxHandling = 'Mailbox RETAINED and left attached - not disabled, so retention does not start'
    })
}
""",
    backup="""
$rollbackDir = Join-Path $env:ProgramData 'ITAutomation\\Rollback'
if (-not (Test-Path -LiteralPath $rollbackDir)) { New-Item -Path $rollbackDir -ItemType Directory -Force | Out-Null }
$rollbackPath = Join-Path $rollbackDir ('offboard-onprem-{0}-{1}.json' -f $item.Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
$item | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $rollbackPath -Encoding UTF8
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Pre-change state written to {0}' -f $rollbackPath)
""",
    act="""
Disable-ADAccount -Identity $item.Id @adArgs

$alphabet = ([char[]]((48..57) + (65..90) + (97..122) + (33,35,36,37,38,42,43,45,61,63,64,95)))
$newSecurePassword = New-Object System.Security.SecureString
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $buf = New-Object byte[] 1
    $limit = [byte](256 - (256 % $alphabet.Length))
    for ($i = 0; $i -lt 24; $i++) {
        do { $rng.GetBytes($buf) } while ($buf[0] -ge $limit)
        $newSecurePassword.AppendChar($alphabet[$buf[0] % $alphabet.Length])
    }
} finally { $rng.Dispose() }
$newSecurePassword.MakeReadOnly()
Set-ADAccountPassword -Identity $item.Id -NewPassword $newSecurePassword -Reset @adArgs

$removed = 0
foreach ($g in ($item.GroupsToRemove -split '; ')) {
    if (-not $g) { continue }
    try { Remove-ADGroupMember -Identity $g -Members $item.Name -Confirm:$false @adArgs; $removed++ }
    catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                -Message ('Could not remove from {0}: {1}' -f $g, $_.Exception.Message) }
}

try { Set-ADUser -Identity $item.Id -Replace @{ msExchHideFromAddressLists = $true } @adArgs }
catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
            -Message 'Could not hide from address lists' }

$forwarded = $false
if ($item.ForwardToManager) {
    $session = $null
    try {
        $uri = 'http://{0}/PowerShell/' -f $item.ExchangeServer
        $sp = @{ ConfigurationName = 'Microsoft.Exchange'; ConnectionUri = $uri
                 Authentication = 'Kerberos'; ErrorAction = 'Stop' }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $sp.Credential = $Credential }
        $session = New-PSSession @sp
        Import-PSSession $session -CommandName Set-Mailbox -AllowClobber -DisableNameChecking | Out-Null
        Set-Mailbox -Identity $item.Mail -ForwardingSmtpAddress $item.ManagerMail `
            -DeliverToMailboxAndForward $true -ErrorAction Stop
        $forwarded = $true
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
            -Message ('Forwarding to manager failed: {0}' -f $_.Exception.Message)
    } finally {
        if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
    }
}

Move-ADObject -Identity $item.Id -TargetPath $item.LeaversOU @adArgs

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Offboarded: disabled, password reset, {0} group(s) removed, moved to {1}, forwarding to manager: {2}. ' +
    'Mailbox retained. Ticket={3}' -f $removed, $item.LeaversOU, $forwarded, $TicketReference)

$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'Offboarded'
    Detail = ('{0} groups removed; forwarded {1}; rollback at {2}' -f $removed, $forwarded, $rollbackPath)
    Succeeded = $true })
"""),

5: dict(
    file='Invoke-AdOffboardingTask',
    modules=['ActiveDirectory'],
    synopsis='Runs individual offboarding sub-tasks as a selectable set.',
    desc='The offboarding steps as separately selectable operations - disable, move OU, strip '
         'groups, hide from GAL, reset password, set expiry - for cases where the full leaver '
         'sequence is not wanted. Multi-step identity change, so it runs as an approved workflow '
         'with each step logged individually.',
    params=[SERVER, CRED,
            dict(name='Identity', help='Account(s) to act on.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Identity"),
            dict(name='Task', help='Sub-tasks to run, in the order given.',
                 decl="[Parameter(Mandatory)]\n    [ValidateSet('Disable','MoveOU','RemoveGroups','HideFromGal','ResetPassword','SetExpiry')]\n    [string[]]$Task"),
            dict(name='TargetOU', help='Destination OU. Required for MoveOU.',
                 decl="[string]$TargetOU"),
            dict(name='ExpiryDate', help='Account expiry date. Required for SetExpiry.',
                 decl="[datetime]$ExpiryDate"),
            dict(name='KeepGroups', help='Groups to leave in place when running RemoveGroups.',
                 decl="[string[]]$KeepGroups")],
    perms='Delegated user management on the relevant OUs.',
    actionVerb='Run offboarding sub-tasks',
    reason='Offboarding sub-task workflow',
    rollback='Each task is individually reversible: re-enable, move back, re-add groups from the '
             'audit log, unhide, clear expiry. The pre-change state is captured before the first task.',
    notes='Tasks run in the order supplied. Put MoveOU last: moving the object first changes its '
          'distinguished name, and the later tasks would then be operating on a stale identity.',
    examples=[("-Identity jsmith -Task Disable,RemoveGroups -TicketReference HR0012345",
               'REQUEST mode - raises an approval for two sub-tasks.'),
              ("-Identity jsmith -Task Disable,RemoveGroups,MoveOU -TargetOU 'OU=Leavers,DC=contoso,DC=com' -ApprovalReference APR-...",
               'Runs the approved sub-tasks in order.')],
    discover=ADARGS + """
Import-Module ActiveDirectory -ErrorAction Stop

if ($Task -contains 'MoveOU' -and -not $TargetOU) { throw '-TargetOU is required for the MoveOU task.' }
if ($Task -contains 'SetExpiry' -and -not $ExpiryDate) { throw '-ExpiryDate is required for the SetExpiry task.' }
if ($TargetOU) {
    try { Get-ADOrganizationalUnit -Identity $TargetOU @adArgs | Out-Null }
    catch { throw ('Target OU does not exist: {0}' -f $TargetOU) }
}

# MoveOU changes the DN, invalidating it for anything that follows.
if ($Task -contains 'MoveOU' -and $Task[-1] -ne 'MoveOU') {
    Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
        'MoveOU is not the last task. It changes the distinguished name, so later tasks may fail. ' +
        'Reorder with MoveOU last.')
}

foreach ($id in $Identity) {
    $u = Get-ADUser -Identity $id -Properties MemberOf,Enabled,DistinguishedName,DisplayName,AccountExpirationDate @adArgs
    $groups = @($u.MemberOf | ForEach-Object { (Get-ADGroup -Identity $_ @adArgs).Name })
    $toRemove = @($groups | Where-Object { $KeepGroups -notcontains $_ })

    $results.Add([PSCustomObject]@{
        Name            = $u.SamAccountName
        Id              = $u.DistinguishedName
        DisplayName     = $u.DisplayName
        CurrentlyEnabled= $u.Enabled
        CurrentOU       = ($u.DistinguishedName -replace '^CN=[^,]+,', '')
        CurrentExpiry   = $u.AccountExpirationDate
        Tasks           = ($Task -join ' -> ')
        TargetOU        = $TargetOU
        ExpiryDate      = $ExpiryDate
        AllGroups       = ($groups -join '; ')
        GroupsToRemove  = ($toRemove -join '; ')
        RemoveGroupCount= $toRemove.Count
    })
}
""",
    act="""
$done = @()
$currentId = $item.Id

foreach ($t in $Task) {
    switch ($t) {
        'Disable' {
            Disable-ADAccount -Identity $currentId @adArgs
            $done += 'Disable'
        }
        'ResetPassword' {
            $alphabet = ([char[]]((48..57) + (65..90) + (97..122) + (33,35,36,37,38,42,43,45,61,63,64,95)))
            $newSecurePassword = New-Object System.Security.SecureString
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            try {
                $buf = New-Object byte[] 1
                $limit = [byte](256 - (256 % $alphabet.Length))
                for ($i = 0; $i -lt 24; $i++) {
                    do { $rng.GetBytes($buf) } while ($buf[0] -ge $limit)
                    $newSecurePassword.AppendChar($alphabet[$buf[0] % $alphabet.Length])
                }
            } finally { $rng.Dispose() }
            $newSecurePassword.MakeReadOnly()
            Set-ADAccountPassword -Identity $currentId -NewPassword $newSecurePassword -Reset @adArgs
            $done += 'ResetPassword'
        }
        'RemoveGroups' {
            $n = 0
            foreach ($g in ($item.GroupsToRemove -split '; ')) {
                if (-not $g) { continue }
                try { Remove-ADGroupMember -Identity $g -Members $item.Name -Confirm:$false @adArgs; $n++ }
                catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                            -Message ('Could not remove from {0}' -f $g) }
            }
            $done += ('RemoveGroups({0})' -f $n)
        }
        'HideFromGal' {
            try { Set-ADUser -Identity $currentId -Replace @{ msExchHideFromAddressLists = $true } @adArgs
                  $done += 'HideFromGal' }
            catch { Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                        -Message 'Could not hide from address lists (Exchange schema may be absent)' }
        }
        'SetExpiry' {
            Set-ADAccountExpiration -Identity $currentId -DateTime $item.ExpiryDate @adArgs
            $done += ('SetExpiry({0:yyyy-MM-dd})' -f $item.ExpiryDate)
        }
        'MoveOU' {
            Move-ADObject -Identity $currentId -TargetPath $item.TargetOU @adArgs
            # The DN has changed; re-resolve so any later task uses the new one.
            $currentId = (Get-ADUser -Identity $item.Name @adArgs).DistinguishedName
            $done += 'MoveOU'
        }
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message ('Task complete: {0}' -f $t)
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Sub-tasks complete: {0}. Ticket={1} Approval={2}' -f ($done -join ', '), $TicketReference, $ApprovalReference)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'SubTasksRun'; Detail = ($done -join ', '); Succeeded = $true })
"""),

6: dict(
    file='Set-AdShareFolderAccess',
    modules=['ActiveDirectory'],
    synopsis='Creates a shared folder and applies group-based NTFS permissions.',
    desc='Creates a folder, shares it and applies NTFS access rules to security groups. Grants are '
         'made to groups rather than individual users, because per-user ACLs are how a share '
         'becomes unauditable within a year.',
    params=[CRED,
            dict(name='ComputerName', help='File server hosting the share.',
                 decl="[Parameter(Mandatory)]\n    [string]$ComputerName"),
            dict(name='FolderPath', help='Local path on the file server.',
                 decl="[Parameter(Mandatory)]\n    [string]$FolderPath"),
            dict(name='ShareName', help='Share name to create.',
                 decl="[string]$ShareName"),
            dict(name='AccessGroup', help='Security group(s) to grant access to. Users are not accepted.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$AccessGroup"),
            dict(name='AccessRight', help='NTFS right to grant.',
                 decl="[ValidateSet('ReadAndExecute','Modify','FullControl')]\n    [string]$AccessRight = 'Modify'"),
            dict(name='DisableInheritance', help='Break inheritance on the new folder so only the explicit grants apply.',
                 decl="[switch]$DisableInheritance")],
    perms='Local Administrator on the file server, plus read access to AD to resolve the groups.',
    actionVerb='Create share and apply ACL',
    reason='Shared folder provisioning',
    rollback='Remove the share and the folder, or restore the previous ACL from the export written '
             'before the change.',
    notes='Only security GROUPS are accepted, not user accounts. A share whose ACL is a list of '
          'individuals cannot be reviewed meaningfully and breaks the moment someone leaves.',
    examples=[("-ComputerName FS01 -FolderPath 'D:\\\\Shares\\\\Finance' -ShareName Finance -AccessGroup 'GG-Finance-RW' -TicketReference REQ0012345",
               'REQUEST mode - raises an approval for the share and ACL.'),
              ("-ComputerName FS01 -FolderPath 'D:\\\\Shares\\\\Finance' -AccessGroup 'GG-Finance-RW' -ApprovalReference APR-...",
               'Creates the approved share.')],
    discover="""
Import-Module ActiveDirectory -ErrorAction Stop

$adArgs = @{ ErrorAction = 'Stop' }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $adArgs.Credential = $Credential }

# Groups only. A per-user ACL is unauditable and breaks on every leaver.
foreach ($g in $AccessGroup) {
    $obj = Get-ADObject -Filter ("SamAccountName -eq '{0}'" -f ($g -replace '^.*\\\\', '')) `
           -Properties objectClass @adArgs -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $obj) { throw ('Access principal not found in AD: {0}' -f $g) }
    if ($obj.objectClass -ne 'group') {
        throw ('{0} is a {1}, not a group. This script grants access to security groups only.' -f $g, $obj.objectClass)
    }
}

if (-not $ShareName) { $ShareName = Split-Path -Leaf $FolderPath }

$exists = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
    [PSCustomObject]@{
        FolderExists = Test-Path -LiteralPath $using:FolderPath
        ShareExists  = [bool](Get-SmbShare -Name $using:ShareName -ErrorAction SilentlyContinue)
    }
} -ErrorAction Stop

if ($exists.ShareExists) {
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ShareName `
        -Message 'Share already exists - ACL will be updated, share not recreated'
}

$results.Add([PSCustomObject]@{
    Name             = ('\\\\{0}\\{1}' -f $ComputerName, $ShareName)
    Id               = $FolderPath
    ComputerName     = $ComputerName
    FolderPath       = $FolderPath
    ShareName        = $ShareName
    AccessGroups     = ($AccessGroup -join '; ')
    AccessRight      = $AccessRight
    FolderExists     = $exists.FolderExists
    ShareExists      = $exists.ShareExists
    DisableInheritance = [bool]$DisableInheritance
})
""",
    act="""
# Values are bound into locals first so the remote scriptblock can reference
# them with $using: rather than positional arguments.
$remotePath   = $item.FolderPath
$remoteShare  = $item.ShareName
$remoteGroups = $item.AccessGroups.Split('; ')
$remoteRight  = $item.AccessRight
$remoteBreak  = $item.DisableInheritance

$result = Invoke-Command -ComputerName $item.ComputerName -ScriptBlock {
    $Path         = $using:remotePath
    $Share        = $using:remoteShare
    $Groups       = $using:remoteGroups
    $Right        = $using:remoteRight
    $BreakInherit = $using:remoteBreak

    $created = $false
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        $created = $true
    }

    # Capture the existing ACL so it can be restored if the change is wrong.
    $priorAcl = (Get-Acl -LiteralPath $Path).Access |
        ForEach-Object { '{0}:{1}' -f $_.IdentityReference, $_.FileSystemRights } | Sort-Object -Unique

    $acl = Get-Acl -LiteralPath $Path
    if ($BreakInherit) { $acl.SetAccessRuleProtection($true, $true) }

    foreach ($g in $Groups) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $g, $Right, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl

    $shareCreated = $false
    if (-not (Get-SmbShare -Name $Share -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $Share -Path $Path -FullAccess 'Authenticated Users' | Out-Null
        $shareCreated = $true
    }

    [PSCustomObject]@{
        FolderCreated = $created; ShareCreated = $shareCreated
        PriorAcl = ($priorAcl -join '; ')
    }
} -ErrorAction Stop

Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Prior ACL captured: {0}' -f $result.PriorAcl)
Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Share ready. Folder created={0}, share created={1}, {2} granted to {3}. Ticket={4}' -f
    $result.FolderCreated, $result.ShareCreated, $item.AccessRight, $item.AccessGroups, $TicketReference)

$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'ShareConfigured'
    Detail = ('{0} to {1}' -f $item.AccessRight, $item.AccessGroups); Succeeded = $true })
"""),

7: dict(
    file='Reset-AdUserPassword',
    modules=['ActiveDirectory'],
    synopsis='Resets an Active Directory password or unlocks an account.',
    desc='Resets a password, unlocks a locked-out account, or both. A password reset request is a '
         'standard social-engineering approach, so this requires approval, a ticket reference, and '
         'explicit confirmation that the requester was verified out of band.',
    params=[SERVER, CRED,
            dict(name='Identity', help='Account(s) to act on.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Identity"),
            dict(name='Operation', help='ResetPassword, Unlock, or Both.',
                 decl="[ValidateSet('ResetPassword','Unlock','Both')]\n    [string]$Operation = 'Both'"),
            dict(name='IdentityVerifiedOutOfBand', help='Confirms the requester was verified by a channel other than email. Required for a password reset.',
                 decl="[switch]$IdentityVerifiedOutOfBand"),
            dict(name='ChangeAtNextLogon', help='Force a password change at next logon. On by default.',
                 decl="[bool]$ChangeAtNextLogon = $true"),
            dict(name='NewPassword', help='Specific password as a SecureString. Generated if omitted.',
                 decl="[System.Security.SecureString]$NewPassword")],
    perms='Delegated Reset Password and Unlock Account on the target OU.',
    actionVerb='Reset password / unlock account',
    reason='Password reset or account unlock (verified)',
    rollback='NONE for the password - the previous value cannot be restored. An unlock is harmless '
             'and needs no rollback.',
    notes='Unlock alone does not require out-of-band verification, because it restores access to '
          'somebody who already knows the password. A RESET grants access to whoever receives the '
          'new one, which is why it does.',
    examples=[("-Identity jsmith -Operation Unlock -TicketReference INC0012345",
               'REQUEST mode - raises an approval for an unlock.'),
              ("-Identity jsmith -Operation Both -TicketReference INC0012345 -IdentityVerifiedOutOfBand -ApprovalReference APR-...",
               'Resets the password and unlocks the account.')],
    discover=ADARGS + """
Import-Module ActiveDirectory -ErrorAction Stop

if (-not $TicketReference) { throw 'A -TicketReference is required.' }
if ($Operation -in @('ResetPassword','Both') -and -not $IdentityVerifiedOutOfBand) {
    throw 'Refusing to reset a password without -IdentityVerifiedOutOfBand. Verify the requester by ' +
          'phone or in person - an emailed request is exactly what an attacker sends.'
}

foreach ($id in $Identity) {
    $u = Get-ADUser -Identity $id -Properties LockedOut,Enabled,PasswordLastSet,LastLogonDate,DistinguishedName,DisplayName @adArgs

    if ($Operation -eq 'Unlock' -and -not $u.LockedOut) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $id `
            -Message 'Skipped - account is not locked out (idempotent)'
        continue
    }

    $results.Add([PSCustomObject]@{
        Name            = $u.SamAccountName
        Id              = $u.DistinguishedName
        DisplayName     = $u.DisplayName
        Enabled         = $u.Enabled
        LockedOut       = $u.LockedOut
        PasswordLastSet = $u.PasswordLastSet
        LastLogon       = $u.LastLogonDate
        Operation       = $Operation
        ChangeAtNextLogon = $ChangeAtNextLogon
        VerifiedOutOfBand = [bool]$IdentityVerifiedOutOfBand
        Ticket          = $TicketReference
    })
}
""",
    act="""
$didReset = $false
$didUnlock = $false

if ($item.Operation -in @('ResetPassword','Both')) {
    if ($NewPassword) {
        $newSecurePassword = $NewPassword
        $plainForDisplay = $null
    } else {
        # Generated into a SecureString; a display copy is produced separately
        # only because the operator must be able to communicate it.
        $alphabet = ([char[]]((48..57) + (65..90) + (97..122) + (33,35,36,37,38,42,43,45,61,63,64,95)))
        $chars = @()
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $buf = New-Object byte[] 1
            $limit = [byte](256 - (256 % $alphabet.Length))
            for ($i = 0; $i -lt 20; $i++) {
                do { $rng.GetBytes($buf) } while ($buf[0] -ge $limit)
                $chars += $alphabet[$buf[0] % $alphabet.Length]
            }
        } finally { $rng.Dispose() }
        $plainForDisplay = -join $chars
        $newSecurePassword = New-Object System.Security.SecureString
        foreach ($c in $chars) { $newSecurePassword.AppendChar($c) }
        $newSecurePassword.MakeReadOnly()
    }

    Set-ADAccountPassword -Identity $item.Id -NewPassword $newSecurePassword -Reset @adArgs
    if ($item.ChangeAtNextLogon) {
        Set-ADUser -Identity $item.Id -ChangePasswordAtLogon $true @adArgs
    }
    $didReset = $true

    if ($plainForDisplay) {
        # Information stream, never the success pipeline - so it cannot end up
        # in a CSV, a JSON export, or the log file.
        Write-Information (@(
            ''
            ('  New password for {0}:' -f $item.Name)
            ('  {0}' -f $plainForDisplay)
            '  Communicate through the agreed channel. Shown once, not stored.'
            ''
        ) -join [Environment]::NewLine) -InformationAction Continue
    }
}

if ($item.Operation -in @('Unlock','Both') -and $item.LockedOut) {
    Unlock-ADAccount -Identity $item.Id @adArgs
    $didUnlock = $true
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'Reset={0} Unlock={1} ChangeAtNextLogon={2}. Ticket={3} OutOfBandVerified={4}. Password NOT logged.' -f
    $didReset, $didUnlock, $item.ChangeAtNextLogon, $TicketReference, $item.VerifiedOutOfBand)

$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = $item.Operation
    Detail = ('reset={0}; unlock={1}' -f $didReset, $didUnlock); Succeeded = $true })
"""),

8: dict(
    file='Set-AdUserAttribute',
    modules=['ActiveDirectory'],
    synopsis='Modifies Active Directory user attributes per a ticket.',
    desc='Updates directory attributes such as title, department, manager or telephone. The prior '
         'value of every attribute is captured before the change, so the audit trail answers what '
         'it was as well as what it became.',
    params=[SERVER, CRED,
            dict(name='Identity', help='Account(s) to modify.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Identity"),
            dict(name='Attribute', help='Attributes and new values, e.g. @{ Title = \\u2018Manager\\u2019; Department = \\u2018Finance\\u2019 }.',
                 decl="[Parameter(Mandatory)]\n    [hashtable]$Attribute"),
            dict(name='AllowedAttribute', help='Attributes this script may change. Anything outside the list is refused.',
                 decl="[string[]]$AllowedAttribute = @('Title','Department','Company','Office','OfficePhone','MobilePhone','Manager','Description','StreetAddress','City','State','PostalCode','Country','EmployeeID','EmployeeNumber')")],
    perms='Delegated write on the specific attributes for the target OU.',
    actionVerb='Modify user attributes',
    reason='Directory attribute change',
    rollback='Re-run with the prior values, which are recorded in the audit log before the change.',
    notes='The allow-list deliberately excludes security-relevant attributes such as '
          'userAccountControl, memberOf, and anything under msExch or msDS. Those have their own '
          'scripts and their own approval paths; folding them in here would let a routine attribute '
          'ticket change group membership.',
    examples=[("-Identity jsmith -Attribute @{Title='Senior Analyst';Department='Finance'} -TicketReference REQ0012345",
               'REQUEST mode - raises an approval showing old and new values.'),
              ("-Identity jsmith -Attribute @{Title='Senior Analyst'} -ApprovalReference APR-...",
               'Applies the approved change.')],
    discover=ADARGS + """
Import-Module ActiveDirectory -ErrorAction Stop

foreach ($key in $Attribute.Keys) {
    if ($AllowedAttribute -notcontains $key) {
        throw ('Refusing to modify "{0}" - it is not in -AllowedAttribute. Security-relevant ' +
               'attributes have their own scripts and approval paths.' -f $key)
    }
}

foreach ($id in $Identity) {
    $props = @($Attribute.Keys) + @('DistinguishedName','DisplayName')
    $u = Get-ADUser -Identity $id -Properties $props @adArgs

    $changes = @()
    $priorValues = @{}
    foreach ($key in $Attribute.Keys) {
        $old = $u.$key
        $new = $Attribute[$key]
        $priorValues[$key] = "$old"
        if ("$old" -eq "$new") { continue }              # idempotent
        $changes += ('{0}: "{1}" -> "{2}"' -f $key, $old, $new)
    }

    if ($changes.Count -eq 0) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $id `
            -Message 'Skipped - all attributes already at the requested values (idempotent)'
        continue
    }

    $results.Add([PSCustomObject]@{
        Name        = $u.SamAccountName
        Id          = $u.DistinguishedName
        DisplayName = $u.DisplayName
        Changes     = ($changes -join '; ')
        ChangeCount = $changes.Count
        PriorValues = $priorValues
        NewValues   = $Attribute
        Ticket      = $TicketReference
    })
}
""",
    act="""
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Prior values: {0}' -f (($item.PriorValues.GetEnumerator() | ForEach-Object { '{0}="{1}"' -f $_.Key, $_.Value }) -join '; '))

$setParams = @{ Identity = $item.Id }
$replace = @{}
foreach ($key in $item.NewValues.Keys) {
    # Manager takes a DN; the rest are ordinary attribute writes.
    if ($key -eq 'Manager') { $setParams.Manager = $item.NewValues[$key] }
    else { $replace[$key] = $item.NewValues[$key] }
}
if ($replace.Count -gt 0) { $setParams.Replace = $replace }

Set-ADUser @setParams @adArgs

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    '{0} attribute(s) changed: {1}. Ticket={2}' -f $item.ChangeCount, $item.Changes, $TicketReference)
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'AttributesChanged'; Detail = $item.Changes; Succeeded = $true })
"""),

9: dict(
    file='Set-AdAccountExpiry',
    modules=['ActiveDirectory'],
    synopsis='Sets or clears the expiry date on an Active Directory account.',
    desc='Applies an account expiry date, typically for a contractor or a temporary account. Low '
         'risk and fully reversible, so it executes directly - but the script refuses a date in the '
         'past, which would disable the account immediately and usually is not what was meant.',
    params=[SERVER, CRED,
            dict(name='Identity', help='Account(s) to set expiry on.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$Identity"),
            dict(name='ExpiryDate', help='Date the account expires. Omit with -ClearExpiry to remove it.',
                 decl="[datetime]$ExpiryDate"),
            dict(name='ClearExpiry', help='Remove the expiry date so the account never expires.',
                 decl="[switch]$ClearExpiry"),
            dict(name='AllowPastDate', help='Permit a date in the past, which disables the account immediately.',
                 decl="[switch]$AllowPastDate")],
    perms='Delegated write on accountExpires for the target OU.',
    actionVerb='Set account expiry',
    rollback='Re-run with the previous date, or -ClearExpiry. The prior value is recorded first.',
    notes='AD stores expiry as end-of-day. An account set to expire on the 31st remains usable '
          'through that day and is disabled at midnight.',
    examples=[("-Identity contractor1 -ExpiryDate '2026-12-31'",
               'Sets an expiry date.'),
              ("-Identity contractor1 -ClearExpiry",
               'Removes the expiry so the account no longer expires.')],
    discover=ADARGS + """
Import-Module ActiveDirectory -ErrorAction Stop

if (-not $ClearExpiry -and -not $ExpiryDate) {
    throw 'Specify -ExpiryDate, or -ClearExpiry to remove the expiry.'
}
if ($ExpiryDate -and $ExpiryDate -lt (Get-Date) -and -not $AllowPastDate) {
    throw ('Refusing: {0:yyyy-MM-dd} is in the past and would disable the account immediately. ' +
           'Pass -AllowPastDate if that is genuinely intended.' -f $ExpiryDate)
}

foreach ($id in $Identity) {
    $u = Get-ADUser -Identity $id -Properties AccountExpirationDate,Enabled,DistinguishedName,DisplayName @adArgs

    $current = $u.AccountExpirationDate
    $wanted = if ($ClearExpiry) { $null } else { $ExpiryDate }

    if (("$current" -eq "$wanted")) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $id `
            -Message 'Skipped - expiry already at the requested value (idempotent)'
        continue
    }

    $results.Add([PSCustomObject]@{
        Name          = $u.SamAccountName
        Id            = $u.DistinguishedName
        DisplayName   = $u.DisplayName
        Enabled       = $u.Enabled
        CurrentExpiry = $current
        NewExpiry     = $wanted
        Operation     = if ($ClearExpiry) { 'Clear' } else { 'Set' }
        DaysUntilExpiry = if ($wanted) { [math]::Round(($wanted - (Get-Date)).TotalDays, 0) } else { $null }
    })
}
""",
    act="""
Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $label -Message (
    'Prior expiry: {0}' -f $(if ($item.CurrentExpiry) { $item.CurrentExpiry } else { 'never' }))

if ($item.Operation -eq 'Clear') {
    Clear-ADAccountExpiration -Identity $item.Id @adArgs
    $detail = 'expiry cleared - account no longer expires'
} else {
    Set-ADAccountExpiration -Identity $item.Id -DateTime $item.NewExpiry @adArgs
    $detail = 'expires {0:yyyy-MM-dd} ({1} day(s))' -f $item.NewExpiry, $item.DaysUntilExpiry
}

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message $detail
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = ('Expiry' + $item.Operation); Detail = $detail; Succeeded = $true })
"""),

10: dict(
    file='Get-AdHealthReport',
    modules=['ActiveDirectory'],
    synopsis='Reports Active Directory replication, domain controller and FSMO health.',
    desc='Checks replication status between domain controllers, DC service availability, FSMO role '
         'placement and SYSVOL replication. Replication failure is the condition that silently '
         'breaks authentication in ways that look like everything else, so it is reported first.',
    params=[SERVER, CRED,
            dict(name='MaxReplicationLagMinutes', help='Flag a replication partner whose last successful sync is older than this.',
                 decl="[ValidateRange(1,10080)]\n    [int]$MaxReplicationLagMinutes = 60")],
    perms='Domain read access. Replication metadata needs at least Domain Users on most directories.',
    examples=[("-OutputFormat HTML", 'Full AD health report as HTML.'),
              ("-MaxReplicationLagMinutes 30", 'Applies a tighter replication threshold.')],
    discover=ADARGS + """
Import-Module ActiveDirectory -ErrorAction Stop

# --- domain controllers ---------------------------------------------------
$dcs = @(Get-ADDomainController -Filter * @adArgs)
foreach ($dc in $dcs) {
    $reachable = $false
    try { $reachable = Test-Connection -ComputerName $dc.HostName -Count 1 -Quiet -ErrorAction Stop } catch {
        Write-Verbose ('Ping failed for {0}' -f $dc.HostName)
    }

    $issues = @()
    if (-not $reachable) { $issues += 'not reachable' }

    $results.Add([PSCustomObject]@{
        Name        = $dc.HostName
        Id          = $dc.HostName
        RecordType  = 'DomainController'
        Site        = $dc.Site
        IsGlobalCatalog = $dc.IsGlobalCatalog
        IsReadOnly  = $dc.IsReadOnly
        OperatingSystem = $dc.OperatingSystem
        IPv4Address = $dc.IPv4Address
        FsmoRoles   = ($dc.OperationMasterRoles -join '; ')
        Reachable   = $reachable
        Status      = if ($issues.Count) { 'Warning' } else { 'OK' }
        Issues      = ($issues -join '; ')
    })
}

# --- replication ----------------------------------------------------------
foreach ($dc in $dcs) {
    $partners = @()
    try {
        $partners = @(Get-ADReplicationPartnerMetadata -Target $dc.HostName -ErrorAction Stop)
    } catch {
        Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $dc.HostName `
            -Message ('Replication metadata unavailable: {0}' -f $_.Exception.Message)
        continue
    }

    foreach ($p in $partners) {
        $lagMin = if ($p.LastReplicationSuccess) {
                      [math]::Round(((Get-Date) - $p.LastReplicationSuccess).TotalMinutes, 1)
                  } else { $null }

        $issues = @()
        if ($p.LastReplicationResult -ne 0) { $issues += ('last result {0}' -f $p.LastReplicationResult) }
        if ($null -eq $lagMin)              { $issues += 'never replicated successfully' }
        elseif ($lagMin -gt $MaxReplicationLagMinutes) { $issues += ('lag {0} min' -f $lagMin) }

        $results.Add([PSCustomObject]@{
            Name        = ('{0} <- {1}' -f $dc.HostName, ($p.Partner -replace '^CN=NTDS Settings,CN=([^,]+).*$', '$1'))
            Id          = $p.Partner
            RecordType  = 'Replication'
            Site        = $dc.Site
            Partition   = $p.Partition
            LastSuccess = $p.LastReplicationSuccess
            LagMinutes  = $lagMin
            LastResult  = $p.LastReplicationResult
            ConsecutiveFailures = $p.ConsecutiveReplicationFailures
            Status      = if ($issues.Count) { 'Unhealthy' } else { 'Healthy' }
            Issues      = ($issues -join '; ')
        })
        if ($issues.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $dc.HostName -Message (
                'Replication issue with {0}: {1}' -f $p.Partner, ($issues -join '; '))
        }
    }
}

# --- FSMO placement -------------------------------------------------------
$forest = Get-ADForest @adArgs
$domain = Get-ADDomain @adArgs
$results.Add([PSCustomObject]@{
    Name       = 'FSMO role placement'
    Id         = 'fsmo'
    RecordType = 'FSMO'
    SchemaMaster        = $forest.SchemaMaster
    DomainNamingMaster  = $forest.DomainNamingMaster
    PDCEmulator         = $domain.PDCEmulator
    RIDMaster           = $domain.RIDMaster
    InfrastructureMaster= $domain.InfrastructureMaster
    Status     = 'Info'
})
"""),

11: dict(
    file='Get-AdComputerAddress',
    modules=['ActiveDirectory'],
    synopsis='Resolves hostnames and IP addresses for Active Directory computers.',
    desc='Looks up computer objects and resolves their current DNS addresses, reporting where AD '
         'and DNS disagree. A stale DNS record pointing at a reused address is a common cause of '
         'connecting to the wrong machine, and this surfaces it.',
    params=[SERVER, CRED,
            dict(name='ComputerName', help='Computer name(s) to look up. Accepts partial names with wildcards.',
                 decl="[string[]]$ComputerName"),
            dict(name='IPAddress', help='Reverse lookup: find which computer holds this address.',
                 decl="[string[]]$IPAddress"),
            dict(name='StaleDays', help='Flag a computer whose AD password was last set longer ago than this.',
                 decl="[ValidateRange(1,3650)]\n    [int]$StaleDays = 90")],
    perms='Domain read access.',
    examples=[("-ComputerName 'SRV*'", 'Resolves every computer whose name starts with SRV.'),
              ("-IPAddress 10.1.2.3", 'Finds which computer currently answers on that address.')],
    discover=ADARGS + """
Import-Module ActiveDirectory -ErrorAction Stop

if ($IPAddress) {
    foreach ($ip in $IPAddress) {
        $hostName = $null
        try { $hostName = [System.Net.Dns]::GetHostEntry($ip).HostName } catch {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $ip `
                -Message 'No reverse DNS record'
        }

        $adComputer = $null
        if ($hostName) {
            $short = ($hostName -split '\\.')[0]
            $adComputer = Get-ADComputer -Filter ("Name -eq '{0}'" -f $short) `
                -Properties OperatingSystem,PasswordLastSet,Description @adArgs -ErrorAction SilentlyContinue
        }

        $results.Add([PSCustomObject]@{
            Name         = if ($hostName) { $hostName } else { $ip }
            Id           = $ip
            LookupType   = 'Reverse'
            QueriedValue = $ip
            ResolvedHost = $hostName
            InActiveDirectory = [bool]$adComputer
            DistinguishedName = if ($adComputer) { $adComputer.DistinguishedName } else { $null }
            OperatingSystem   = if ($adComputer) { $adComputer.OperatingSystem } else { $null }
            PasswordLastSet   = if ($adComputer) { $adComputer.PasswordLastSet } else { $null }
            Status       = if (-not $hostName) { 'NoDnsRecord' }
                           elseif (-not $adComputer) { 'DnsButNotInAD' }
                           else { 'OK' }
        })
    }
    return
}

$filter = if ($ComputerName) { $ComputerName } else { @('*') }
foreach ($pattern in $filter) {
    $computers = Get-ADComputer -Filter ("Name -like '{0}'" -f $pattern) `
        -Properties OperatingSystem,PasswordLastSet,DNSHostName,Description,Enabled @adArgs

    foreach ($c in $computers) {
        $resolved = @()
        try { $resolved = @([System.Net.Dns]::GetHostAddresses($c.DNSHostName) |
                           Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                           ForEach-Object { $_.IPAddressToString }) } catch {
            Write-Verbose ('DNS resolution failed for {0}' -f $c.DNSHostName)
        }

        $staleDaysActual = if ($c.PasswordLastSet) {
                               [math]::Round(((Get-Date) - $c.PasswordLastSet).TotalDays, 0)
                           } else { $null }

        $issues = @()
        if ($resolved.Count -eq 0) { $issues += 'does not resolve in DNS' }
        if ($null -ne $staleDaysActual -and $staleDaysActual -gt $StaleDays) {
            $issues += ('computer password {0}d old - object may be stale' -f $staleDaysActual)
        }
        if (-not $c.Enabled) { $issues += 'account disabled' }

        $results.Add([PSCustomObject]@{
            Name         = $c.Name
            Id           = $c.DistinguishedName
            LookupType   = 'Forward'
            QueriedValue = $pattern
            DnsHostName  = $c.DNSHostName
            IPAddresses  = ($resolved -join '; ')
            OperatingSystem = $c.OperatingSystem
            Enabled      = $c.Enabled
            PasswordLastSet = $c.PasswordLastSet
            StaleDays    = $staleDaysActual
            Description  = $c.Description
            Status       = if ($issues.Count) { 'Warning' } else { 'OK' }
            Issues       = ($issues -join '; ')
        })
    }
}
"""),

12: dict(
    file='New-AdOrganizationalUnit',
    modules=['ActiveDirectory'],
    synopsis='Creates an Active Directory organisational unit with accidental-deletion protection.',
    desc='Creates an OU under a parent path, with protection from accidental deletion enabled by '
         'default. Additive and low risk, but the naming convention is enforced in code and the '
         'parent must already exist, so a typo cannot create an OU in an unexpected part of the tree.',
    params=[SERVER, CRED,
            dict(name='OuName', help='Name of the OU to create.',
                 decl="[Parameter(Mandatory)]\n    [string[]]$OuName"),
            dict(name='ParentPath', help='Distinguished name of the parent container.',
                 decl="[Parameter(Mandatory)]\n    [string]$ParentPath"),
            dict(name='NamingPattern', help='Wildcard pattern the OU name must match. Set to * to disable.',
                 decl="[string]$NamingPattern = '*'"),
            dict(name='ProtectFromDeletion', help='Enable accidental-deletion protection. On by default.',
                 decl="[bool]$ProtectFromDeletion = $true"),
            dict(name='Description', help='Description for the new OU.',
                 decl="[string]$Description")],
    perms='Delegated Create Organizational Unit Objects on the parent container.',
    actionVerb='Create organisational unit',
    rollback='Remove-ADOrganizationalUnit. Deletion protection must be cleared first, which is the '
             'point of enabling it.',
    notes='ProtectFromDeletion defaults to true. An OU deleted by accident takes every object '
          'beneath it, and recovering that means an authoritative restore - considerably more '
          'painful than clearing a checkbox when a deletion is genuinely intended.',
    examples=[("-OuName Contractors -ParentPath 'OU=Users,DC=contoso,DC=com'",
               'Creates a protected OU.'),
              ("-OuName Contractors -ParentPath 'OU=Users,DC=contoso,DC=com' -WhatIf",
               'Shows what would be created.')],
    discover=ADARGS + """
Import-Module ActiveDirectory -ErrorAction Stop

try { Get-ADObject -Identity $ParentPath @adArgs | Out-Null }
catch { throw ('Parent path does not exist: {0}' -f $ParentPath) }

foreach ($name in $OuName) {
    if ($NamingPattern -ne '*' -and $name -notlike $NamingPattern) {
        throw ('Refusing to create "{0}": it does not match the naming pattern "{1}".' -f $name, $NamingPattern)
    }

    $dn = 'OU={0},{1}' -f $name, $ParentPath
    if (Get-ADOrganizationalUnit -Filter ("Name -eq '{0}'" -f $name) -SearchBase $ParentPath `
            -SearchScope OneLevel @adArgs -ErrorAction SilentlyContinue) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $dn `
            -Message 'Skipped - OU already exists (idempotent)'
        continue
    }

    $results.Add([PSCustomObject]@{
        Name             = $name
        Id               = $dn
        DistinguishedName= $dn
        ParentPath       = $ParentPath
        Description      = $Description
        ProtectFromDeletion = $ProtectFromDeletion
    })
}
""",
    act="""
$newParams = @{
    Name = $item.Name
    Path = $item.ParentPath
    ProtectedFromAccidentalDeletion = $item.ProtectFromDeletion
}
if ($item.Description) { $newParams.Description = $item.Description }

New-ADOrganizationalUnit @newParams @adArgs

Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
    'OU created: {0}, deletion protection {1}' -f
    $item.DistinguishedName, $(if ($item.ProtectFromDeletion) { 'ENABLED' } else { 'disabled' }))
$actions.Add([PSCustomObject]@{
    Name = $item.Name; Action = 'OuCreated'
    Detail = $item.DistinguishedName; Succeeded = $true })
"""),
}
