<#
.SYNOPSIS
    Creates an Active Directory user for onboarding with an on-premises
    Exchange mailbox.

.DESCRIPTION
    Creates the AD account and enables an on-premises Exchange mailbox in one
    operation. Unlike the cloud variant, the mailbox genuinely is created
    here, because Enable-Mailbox runs against the local Exchange organisation
    rather than waiting on a directory sync.

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
    UPN suffix for the account.

.PARAMETER MailboxDatabase
    Exchange mailbox database to create the mailbox in.

.PARAMETER ExchangeServer
    Exchange server hosting the management endpoint.

.PARAMETER RoleGroup
    Security groups to add the user to.

.PARAMETER InitialPassword
    Initial password as a SecureString. Generated if omitted.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\New-AdUserOnboardingOnPrem.ps1 -SamAccountName jsmith -GivenName John -Surname Smith -TargetOU 'OU=Joiners,DC=contoso,DC=com' -UpnSuffix contoso.com -ExchangeServer ex01.contoso.com

    Creates the account and enables an on-premises mailbox.

.EXAMPLE
    .\New-AdUserOnboardingOnPrem.ps1 -SamAccountName jsmith -GivenName John -Surname Smith -TargetOU '...' -UpnSuffix contoso.com -ExchangeServer ex01 -WhatIf

    Shows what would be created.

.NOTES
    Source use case      : #2 - User Onboarding - mailbox in Exchange
    Category             : AD & Identity
    Technology           : AD & Exchange PowerShell
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: No
    Guardrails (col L)   : "Same as above for on-prem Exchange"

    Required permissions : Delegated Create User Objects on the OU, plus Exchange Recipient Management for Enable-Mailbox.
    Required modules     : ActiveDirectory
    Authentication       : Delegated service account with the minimum required
                           AD rights.

    Connects to the on-premises Exchange management endpoint over
    Kerberos. If the account running this does not have Exchange RBAC
    rights, the AD account is still created and the mailbox step fails -
    the script reports that partial outcome rather than claiming success.

    Rollback             : Disable-Mailbox then Remove-ADUser. Disabling the
                           mailbox disconnects it; it is retained for the
                           deleted-mailbox retention period before purging.
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

    [string]$MailboxDatabase,

    [Parameter(Mandatory)]
    [string]$ExchangeServer,

    [string[]]$RoleGroup,

    [System.Security.SecureString]$InitialPassword,

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'New-AdUserOnboardingOnPrem'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #2 (AD & Identity)'

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
        if (-not $PSCmdlet.ShouldProcess($label, 'Create AD user (on-premises mailbox)')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'User Onboarding - mailbox in Exchange'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
