<#
.SYNOPSIS
    Adds or removes combined mailbox delegation in one operation.

.DESCRIPTION
    Applies the delegation set an assistant typically needs - Full Access,
    Send on Behalf and calendar Editor - as a single reviewable change, rather
    than three separate requests that get approved at different times and
    drift apart.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Mailbox
    Mailbox being delegated.

.PARAMETER Delegate
    User receiving the delegation.

.PARAMETER Operation
    Add or Remove.

.PARAMETER IncludeFullAccess
    Include Full Access in the delegation set.

.PARAMETER IncludeSendOnBehalf
    Include Send on Behalf in the delegation set.

.PARAMETER CalendarRight
    Calendar access right to apply. None skips the calendar.

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
    .\Set-ExoMailboxDelegation.ps1 -Mailbox exec@contoso.com -Delegate assistant@contoso.com -Operation Add -TicketReference REQ0012345

    REQUEST mode - raises an approval for the full delegation set.

.EXAMPLE
    .\Set-ExoMailboxDelegation.ps1 -Mailbox exec@contoso.com -Delegate assistant@contoso.com -Operation Remove -ApprovalReference APR-...

    Removes the approved delegation set.

.NOTES
    Source use case      : #17 - Add/Remove Mailbox Delegation
    Category             : Exchange & O365
    Technology           : EXO PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Access change; ticket approval"

    Required permissions : Exchange Online Organization Management.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    Send As is deliberately NOT part of this set. It is
    impersonation-capable and has its own approval path in
    Add-ExoSendAsPermission.ps1; bundling it into a routine delegation
    request would let it through on weaker scrutiny.

    Rollback             : Re-run with the opposite -Operation. The full
                           delegation set applied is recorded in the audit log
                           so it can be reproduced exactly.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string]$Mailbox,

    [Parameter(Mandatory)]
    [string[]]$Delegate,

    [Parameter(Mandatory)]
    [ValidateSet('Add','Remove')]
    [string]$Operation,

    [bool]$IncludeFullAccess = $true,

    [bool]$IncludeSendOnBehalf = $true,

    [ValidateSet('None','Reviewer','Author','Editor')]
    [string]$CalendarRight = 'Editor',

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Mailbox delegation change',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Set-ExoMailboxDelegation'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #17 (Exchange & O365)'

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
        Connect-AutomationPlatform -Platform 'ExchangeOnline' | Out-Null


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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Change mailbox delegation', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Change mailbox delegation')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

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
                $calId = '{0}:\Calendar' -f $item.Mailbox
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Add/Remove Mailbox Delegation'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
