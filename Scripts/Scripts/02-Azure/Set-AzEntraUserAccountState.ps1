<#
.SYNOPSIS
    Enables or disables an Entra ID user account after ticket-verified
    approval.

.DESCRIPTION
    Blocks or restores sign-in for a user. Disabling an account locks a person
    out of every system federated to Entra ID, so this requires both an
    approval reference and a ticket reference, and refuses outright on
    accounts holding privileged directory roles unless that is explicitly
    acknowledged.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER UserPrincipalName
    User(s) to act on.

.PARAMETER Operation
    Disable blocks sign-in; Enable restores it.

.PARAMETER AllowPrivilegedAccount
    Permit acting on an account that holds a directory role. Off by default.

.PARAMETER RevokeSessions
    Also revoke existing refresh tokens so current sessions end immediately.

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
    .\Set-AzEntraUserAccountState.ps1 -UserPrincipalName leaver@contoso.com -Operation Disable -TicketReference INC0012345 -RevokeSessions

    REQUEST mode - raises an approval to block sign-in and end current
    sessions.

.EXAMPLE
    .\Set-AzEntraUserAccountState.ps1 -UserPrincipalName leaver@contoso.com -Operation Disable -TicketReference INC0012345 -ApprovalReference APR-...

    Performs the approved account lock.

.NOTES
    Source use case      : #8 - IT Assist - Account Lock
    Category             : Azure
    Technology           : Az PowerShell / Entra ID
    Difficulty           : Medium
    Agent possible       : Need to check
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Can lock out users; ticket-driven with verification"

    Required permissions : Microsoft Graph User.ReadWrite.All and RoleManagement.Read.Directory.
    Required modules     : Az.Accounts, Microsoft.Graph.Authentication, Microsoft.Graph.Users
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Disabling the account does not end sessions already in progress; an
    issued access token remains valid until it expires. Use
    -RevokeSessions when the intent is to cut access now rather than
    prevent the next sign-in.

    Rollback             : Re-run with the opposite -Operation. Revoked
                           sessions are not restored - the user simply signs in
                           again.
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

    [Parameter(Mandatory)]
    [ValidateSet('Disable','Enable')]
    [string]$Operation,

    [switch]$AllowPrivilegedAccount,

    [switch]$RevokeSessions,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Account lock/unlock (ITSM-verified)',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-AzEntraUserAccountState'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #8 (Azure)'

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


        Connect-MgGraph -Scopes 'User.ReadWrite.All','RoleManagement.Read.Directory' -NoWelcome -ErrorAction Stop

        if (-not $TicketReference) {
            throw 'A -TicketReference is required. Account lock is ticket-driven with requester verification.'
        }

        foreach ($upn in $UserPrincipalName) {
            $u = Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName,AccountEnabled,UserType -ErrorAction Stop

            $wanted = ($Operation -eq 'Enable')
            if ($u.AccountEnabled -eq $wanted) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $upn `
                    -Message ('Skipped - AccountEnabled is already {0}' -f $wanted)
                continue
            }

            # Locking a privileged account can remove the last route into the tenant.
            $roles = @()
            try {
                $roles = @(Get-MgUserMemberOf -UserId $u.Id -All -ErrorAction Stop |
                    Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
                    ForEach-Object { $_.AdditionalProperties.displayName })
            } catch {
                Write-Verbose ('Could not enumerate directory roles for {0}' -f $upn)
            }
            if ($roles.Count -gt 0 -and -not $AllowPrivilegedAccount) {
                throw ('{0} holds directory role(s): {1}. Refusing without -AllowPrivilegedAccount.' -f $upn, ($roles -join ', '))
            }

            $results.Add([PSCustomObject]@{
                Name            = $u.UserPrincipalName
                Id              = $u.Id
                DisplayName     = $u.DisplayName
                CurrentEnabled  = $u.AccountEnabled
                DesiredEnabled  = $wanted
                UserType        = $u.UserType
                DirectoryRoles  = ($roles -join '; ')
                Privileged      = ($roles.Count -gt 0)
                Ticket          = $TicketReference
                RevokeSessions  = [bool]$RevokeSessions
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Change account sign-in state', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Change account sign-in state')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Update-MgUser -UserId $item.Id -AccountEnabled:$item.DesiredEnabled -ErrorAction Stop

            $revoked = $false
            if ($RevokeSessions -and -not $item.DesiredEnabled) {
                try {
                    Revoke-MgUserSignInSession -UserId $item.Id -ErrorAction Stop | Out-Null
                    $revoked = $true
                } catch {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label `
                        -Message ('Account disabled but session revocation failed: {0}' -f $_.Exception.Message)
                }
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'AccountEnabled {0} -> {1}. Sessions revoked: {2}. Ticket={3}' -f
                $item.CurrentEnabled, $item.DesiredEnabled, $revoked, $TicketReference)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = $Operation
                Detail = ('enabled={0}; sessions revoked={1}' -f $item.DesiredEnabled, $revoked); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'IT Assist - Account Lock'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
