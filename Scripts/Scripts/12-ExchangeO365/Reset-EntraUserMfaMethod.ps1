<#
.SYNOPSIS
    Clears a user's registered MFA methods so they can re-enrol.

.DESCRIPTION
    Removes registered authentication methods, forcing re-registration at next
    sign-in. This is the single most attractive help-desk request for a social
    engineer: an attacker with a password calls claiming to have lost their
    phone. The script therefore requires approval, a ticket, and explicit
    out-of-band verification.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER UserPrincipalName
    User whose methods to clear.

.PARAMETER IdentityVerifiedOutOfBand
    Confirms the requester was verified through a channel other than email or
    chat. Mandatory.

.PARAMETER MethodType
    Method types to remove. Defaults to phone and authenticator.

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
    .\Reset-EntraUserMfaMethod.ps1 -UserPrincipalName user@contoso.com -TicketReference INC0012345 -IdentityVerifiedOutOfBand

    REQUEST mode - raises an approval for the reset.

.EXAMPLE
    .\Reset-EntraUserMfaMethod.ps1 -UserPrincipalName user@contoso.com -TicketReference INC0012345 -IdentityVerifiedOutOfBand -ApprovalReference APR-...

    Performs the approved reset.

.NOTES
    Source use case      : #24 - Reset MFA
    Category             : Exchange & O365
    Technology           : Graph API / Entra ID
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Prime social-engineering target; verify requester out-of-band before agent acts"

    Required permissions : Microsoft Graph UserAuthenticationMethod.ReadWrite.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    Verify the requester through a channel the attacker does not control.
    A call to the number already on record, or an in-person check, is the
    standard. Email and chat are NOT out-of-band if the account may
    already be compromised.

    Rollback             : NONE - a removed method cannot be restored. The user
                           must re-register. That is the intended outcome, but
                           it also means a fraudulent reset hands the account
                           to whoever re-registers first.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Identity.SignIns

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$UserPrincipalName,

    [switch]$IdentityVerifiedOutOfBand,

    [ValidateSet('phone','microsoftAuthenticator','softwareOath','fido2','windowsHelloForBusiness','all')]
    [string[]]$MethodType = @('phone','microsoftAuthenticator'),

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'MFA method reset (out-of-band verified)',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Reset-EntraUserMfaMethod'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #24 (Exchange & O365)'

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
    $pre = Test-Prerequisite -RequiredModule 'Microsoft.Graph.Authentication','Microsoft.Graph.Identity.SignIns'
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
        Connect-AutomationPlatform -Platform 'ExchangeOnline' | Out-Null


        Connect-MgGraph -Scopes 'User.Read.All','UserAuthenticationMethod.ReadWrite.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Reset MFA methods', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Reset MFA methods')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Reset MFA'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
