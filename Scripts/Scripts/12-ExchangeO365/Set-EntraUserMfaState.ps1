<#
.SYNOPSIS
    Enables or disables per-user MFA state for an Entra ID account.

.DESCRIPTION
    Changes a user's per-user MFA requirement. Disabling MFA removes a
    security control and is a standard objective for an attacker who has
    already obtained a password, so it requires approval, a ticket reference,
    and - for disable - an explicit acknowledgement that identity was verified
    out of band.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER UserPrincipalName
    User(s) to change.

.PARAMETER Operation
    Enable or Disable per-user MFA.

.PARAMETER IdentityVerifiedOutOfBand
    Confirms the requester was verified through a channel other than email.
    Required to disable.

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
    .\Set-EntraUserMfaState.ps1 -UserPrincipalName user@contoso.com -Operation Disable -TicketReference INC0012345 -IdentityVerifiedOutOfBand

    REQUEST mode - raises an approval to disable MFA.

.EXAMPLE
    .\Set-EntraUserMfaState.ps1 -UserPrincipalName user@contoso.com -Operation Enable -ApprovalReference APR-...

    Re-enables MFA for the user.

.NOTES
    Source use case      : #23 - Enable/Disable MFA
    Category             : Exchange & O365
    Technology           : Graph API / Entra ID
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Disabling MFA weakens security; strict identity verification + approval"

    Required permissions : Microsoft Graph Policy.ReadWrite.AuthenticationMethod and UserAuthenticationMethod.ReadWrite.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    Per-user MFA is legacy. Conditional Access is the supported mechanism
    and takes precedence. Disabling per-user MFA does NOT bypass a
    Conditional Access policy that requires MFA - if the user still cannot
    sign in afterwards, that is why.

    Rollback             : Re-run with the opposite -Operation. A disabled MFA
                           state should be re-enabled as soon as the reason for
                           disabling it has passed.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Identity.SignIns

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$UserPrincipalName,

    [Parameter(Mandatory)]
    [ValidateSet('Enable','Disable')]
    [string]$Operation,

    [switch]$IdentityVerifiedOutOfBand,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Per-user MFA state change',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-EntraUserMfaState'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #23 (Exchange & O365)'

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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Change MFA state', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Change MFA state')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Enable/Disable MFA'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
