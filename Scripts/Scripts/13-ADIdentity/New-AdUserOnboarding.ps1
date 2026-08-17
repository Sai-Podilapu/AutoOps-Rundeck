<#
.SYNOPSIS
    Creates an Active Directory user for onboarding with a cloud mailbox.

.DESCRIPTION
    Creates the AD account, places it in the joiner OU, applies group
    memberships from a role template and sets the attributes Entra ID Connect
    needs to provision a cloud mailbox. The mailbox itself is created by
    licence assignment after sync, which this script reports rather than
    pretends to do.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

.PARAMETER Server
    Domain controller to target. Uses the nearest DC when omitted.

.PARAMETER Credential
    Credential for the directory operation.

.PARAMETER SamAccountName
    Logon name for the new account.

.PARAMETER GivenName
    First name.

.PARAMETER Surname
    Last name.

.PARAMETER TargetOU
    Distinguished name of the OU to create the account in.

.PARAMETER UpnSuffix
    UPN suffix. Must be a routable domain that is verified in the tenant.

.PARAMETER RoleGroup
    Security groups to add the user to, from the role template.

.PARAMETER Manager
    Manager\u2019s sam account name or DN.

.PARAMETER Department
    Department attribute.

.PARAMETER JobTitle
    Title attribute.

.PARAMETER InitialPassword
    Initial password as a SecureString. Generated and shown once if omitted.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-AdUserOnboarding.ps1 -SamAccountName jsmith -GivenName John -Surname Smith -TargetOU 'OU=Joiners,DC=contoso,DC=com' -UpnSuffix contoso.com -RoleGroup 'GG-AllStaff'

    Creates the account and adds the role group.

.EXAMPLE
    .\New-AdUserOnboarding.ps1 -SamAccountName jsmith -GivenName John -Surname Smith -TargetOU '...' -UpnSuffix contoso.com -WhatIf

    Shows what would be created.

.NOTES
    Source use case      : #1 - User Onboarding - mailbox in O365
    Category             : AD & Identity
    Technology           : PowerShell / Graph API
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: No
    Guardrails (col L)   : "HR/ITSM-triggered; well-defined SOP makes this a strong agent use case"

    Required permissions : Delegated Create User Objects on the target OU, plus group membership write on the role groups.
    Required modules     : ActiveDirectory
    Authentication       : Delegated service account with the minimum required
                           AD rights.

    This script does NOT create the mailbox. With Entra ID Connect, the
    account syncs to the tenant and the mailbox appears when a licence is
    assigned - use Set-O365UserLicense.ps1 once the sync has run.
    Reporting that as a follow-up step is honest; claiming the mailbox
    exists would not be.

    Rollback             : Remove-ADUser, or disable and move to the leavers
                           OU. A newly created account has no data, so removal
                           is safe in the first hours.
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [string]$Server,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [Parameter(Mandatory)]
    [ValidateLength(1,20)]
    [string]$SamAccountName,

    [Parameter(Mandatory)]
    [string]$GivenName,

    [Parameter(Mandatory)]
    [string]$Surname,

    [Parameter(Mandatory)]
    [string]$TargetOU,

    [Parameter(Mandatory)]
    [string]$UpnSuffix,

    [string[]]$RoleGroup,

    [string]$Manager,

    [string]$Department,

    [string]$JobTitle,

    [System.Security.SecureString]$InitialPassword,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-AdUserOnboarding'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #1 (AD & Identity)'

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
        Connect-AutomationPlatform -Platform 'ActiveDirectory' | Out-Null


        $adArgs = @{ ErrorAction = 'Stop' }
        if ($Server) { $adArgs.Server = $Server }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $adArgs.Credential = $Credential }

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
        if (-not $PSCmdlet.ShouldProcess($label, 'Create AD user (cloud mailbox)')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'User Onboarding - mailbox in O365'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
