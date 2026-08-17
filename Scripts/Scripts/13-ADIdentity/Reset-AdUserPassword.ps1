<#
.SYNOPSIS
    Resets an Active Directory password or unlocks an account.

.DESCRIPTION
    Resets a password, unlocks a locked-out account, or both. A password reset
    request is a standard social-engineering approach, so this requires
    approval, a ticket reference, and explicit confirmation that the requester
    was verified out of band.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Server
    Domain controller to target. Uses the nearest DC when omitted.

.PARAMETER Credential
    Credential for the directory operation.

.PARAMETER Identity
    Account(s) to act on.

.PARAMETER Operation
    ResetPassword, Unlock, or Both.

.PARAMETER IdentityVerifiedOutOfBand
    Confirms the requester was verified by a channel other than email.
    Required for a password reset.

.PARAMETER ChangeAtNextLogon
    Force a password change at next logon. On by default.

.PARAMETER NewPassword
    Specific password as a SecureString. Generated if omitted.

.PARAMETER ApprovalReference
    Approval token from New-ApprovalRequest, after a human has approved it.
    Without this the script performs no change.

.PARAMETER RequestApproval
    Force REQUEST mode - produce the change set and raise an approval request,
    then stop, even if a reference was supplied.

.PARAMETER TicketReference
    ITSM ticket number recorded in the audit trail alongside the approval
    reference.

.PARAMETER Reason
    Change reason recorded in the approval artifact and the audit log.

.PARAMETER OutputFormat
    Console, CSV, JSON or HTML.

.PARAMETER OutputPath
    Destination file for CSV/JSON/HTML output.

.PARAMETER ConfigPath
    Override the path to Config\config.json.

.EXAMPLE
    .\Reset-AdUserPassword.ps1 -Identity jsmith -Operation Unlock -TicketReference INC0012345

    REQUEST mode - raises an approval for an unlock.

.EXAMPLE
    .\Reset-AdUserPassword.ps1 -Identity jsmith -Operation Both -TicketReference INC0012345 -IdentityVerifiedOutOfBand -ApprovalReference APR-...

    Resets the password and unlocks the account.

.NOTES
    Source use case      : #7 - Reset Password / Unlock Account
    Category             : AD & Identity
    Technology           : PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Verify requester identity (ITSM/out-of-band) before agent resets"

    Required permissions : Delegated Reset Password and Unlock Account on the target OU.
    Required modules     : ActiveDirectory
    Authentication       : Delegated service account with the minimum required
                           AD rights.

    Unlock alone does not require out-of-band verification, because it
    restores access to somebody who already knows the password. A RESET
    grants access to whoever receives the new one, which is why it does.

    Rollback             : NONE for the password - the previous value cannot be
                           restored. An unlock is harmless and needs no
                           rollback.
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
    [string[]]$Identity,

    [ValidateSet('ResetPassword','Unlock','Both')]
    [string]$Operation = 'Both',

    [switch]$IdentityVerifiedOutOfBand,

    [bool]$ChangeAtNextLogon = $true,

    [System.Security.SecureString]$NewPassword,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Password reset or account unlock (verified)',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Reset-AdUserPassword'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #7 (AD & Identity)'

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

    # Risk = High: validate before doing anything at all.
    $pre = Test-Prerequisite -RequiredModule 'ActiveDirectory'
    if (-not $pre.Passed) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Message $pre.Summary
        throw $pre.Summary
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Pre-flight passed.'

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

    if ($RequestApproval -or -not $ApprovalReference) {
        $request = New-ApprovalRequest -ScriptName $scriptName -ChangeSet $candidates `
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Reset password / unlock account', $candidates.Count, $Reason, $TicketReference)
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $request.Reference -Message (
            'REQUEST mode - nothing was changed. Supply -ApprovalReference {0} once approved.' -f $request.Reference)
        Write-Warning ('No change made. Approval reference: {0}' -f $request.Reference)
        Write-Output ([PSCustomObject]@{
            Mode = 'RequestApproval'; ApprovalReference = $request.Reference
            CandidateCount = $candidates.Count; Candidates = $candidates; Changed = $false })
        return
    }

    $approvalCheck = Test-ApprovalReference -Reference $ApprovalReference -ScriptName $scriptName
    if (-not $approvalCheck.IsValid) {
        Write-AutomationLog -ScriptName $scriptName -Level ERROR -Target $ApprovalReference -Message (
            'REFUSED to execute: {0}' -f $approvalCheck.Reason)
        throw ('Approval validation failed: {0}' -f $approvalCheck.Reason)
    }
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $ApprovalReference -Message (
        'Approval accepted. {0} Ticket={1}' -f $approvalCheck.Reason, $TicketReference)

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Reset password / unlock account')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Reset Password / Unlock Account'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
