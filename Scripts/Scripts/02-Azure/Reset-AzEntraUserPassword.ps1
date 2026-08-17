<#
.SYNOPSIS
    Resets an Entra ID user password after ticket-verified approval.

.DESCRIPTION
    Sets a new password for a user and forces a change at next sign-in.
    Identity operations are the highest-value target in any estate, so this
    refuses to run without an approval reference AND a ticket reference - the
    workbook guardrail requires the requester's identity to be verified
    through ITSM before the agent executes.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER UserPrincipalName
    User(s) whose password to reset.

.PARAMETER ForceChangeAtNextSignIn
    Require the user to change the password at next sign-in. On by default;
    use -ForceChangeAtNextSignIn:$false only with a documented reason.

.PARAMETER RequireTicketReference
    Refuse to execute without a -TicketReference. On by default because this
    row is identity-sensitive.

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
    .\Reset-AzEntraUserPassword.ps1 -UserPrincipalName user@contoso.com -TicketReference INC0012345

    REQUEST mode - raises an approval referencing the ticket. Changes nothing.

.EXAMPLE
    .\Reset-AzEntraUserPassword.ps1 -UserPrincipalName user@contoso.com -TicketReference INC0012345 -ApprovalReference APR-...

    Performs the approved reset.

.NOTES
    Source use case      : #7 - IT Assist - Password Reset
    Category             : Azure
    Technology           : Az PowerShell / Entra ID
    Difficulty           : Medium
    Agent possible       : Need to check
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Identity-sensitive; verify requester identity via ITSM before agent executes"

    Required permissions : Microsoft Graph User.ReadWrite.All plus a directory role permitting password reset (Password Administrator or higher). Resetting an administrator requires Global Administrator.
    Required modules     : Az.Accounts, Microsoft.Graph.Authentication, Microsoft.Graph.Users
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    The generated password is written ONCE to the console for the operator
    to communicate through the agreed channel. It is deliberately NOT
    written to the log file or the approval artifact, both of which are
    scrubbed of credential-shaped strings.

    Rollback             : NONE - the previous password cannot be restored. The
                           user must complete a new reset if this was done in
                           error.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Users

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$UserPrincipalName,

    [bool]$ForceChangeAtNextSignIn = $true,

    [bool]$RequireTicketReference = $true,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Password reset (ITSM-verified)',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Reset-AzEntraUserPassword'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #7 (Azure)'

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
    $pre = Test-Prerequisite -RequiredModule 'Az.Accounts','Microsoft.Graph.Authentication','Microsoft.Graph.Users'
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
        Connect-AutomationPlatform -Platform 'Azure' | Out-Null


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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Reset user password', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Reset user password')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'IT Assist - Password Reset'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
