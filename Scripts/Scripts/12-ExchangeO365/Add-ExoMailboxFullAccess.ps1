<#
.SYNOPSIS
    Grants Full Access permission on a mailbox to another user.

.DESCRIPTION
    Gives a trustee full read access to somebody else's mailbox. This is one
    of the most privacy-sensitive changes in a tenant, so it is approval-gated
    and requires a ticket reference; the workbook makes manager or ITSM
    approval mandatory.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER Mailbox
    Target mailbox (UPN or primary SMTP address).

.PARAMETER Trustee
    User being granted or removed (UPN or primary SMTP address).

.PARAMETER AutoMapping
    Auto-map the mailbox into the trustee\u2019s Outlook. Off by default
    because it is disruptive and hard to reverse in the client.

.PARAMETER ExpiryDays
    Record an intended review date in the audit trail. Exchange does not
    expire permissions itself.

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
    .\Add-ExoMailboxFullAccess.ps1 -Mailbox shared@contoso.com -Trustee user@contoso.com -TicketReference REQ0012345

    REQUEST mode - raises an approval. Grants nothing.

.EXAMPLE
    .\Add-ExoMailboxFullAccess.ps1 -Mailbox shared@contoso.com -Trustee user@contoso.com -TicketReference REQ0012345 -ApprovalReference APR-...

    Applies the approved grant.

.NOTES
    Source use case      : #3 - Full Access Addition on Mailbox
    Category             : Exchange & O365
    Technology           : Exchange/EXO PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Grants access to another user's mail; manager/ITSM approval mandatory"

    Required permissions : Exchange Online Organization Management, or a custom role with Mailbox Permissions.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    Exchange does not support time-limited mailbox permissions.
    -ExpiryDays records an intended review date in the audit trail so the
    grant can be found later; it does NOT revoke anything automatically.

    Rollback             : Remove-ExoMailboxFullAccess.ps1, or
                           Remove-MailboxPermission directly. The grant is
                           immediately reversible, but anything the trustee
                           read in the meantime cannot be unread.
#>

#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string[]]$Mailbox,

    [Parameter(Mandatory)]
    [string[]]$Trustee,

    [bool]$AutoMapping = $false,

    [ValidateRange(0,3650)]
    [int]$ExpiryDays = 90,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Full Access mailbox permission grant',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Add-ExoMailboxFullAccess'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #3 (Exchange & O365)'

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
    $pre = Test-Prerequisite -RequiredModule 'ExchangeOnlineManagement'
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

        if (-not $TicketReference) {
            throw 'A -TicketReference is required. Full Access grants need manager or ITSM approval per the SOP.'
        }

        foreach ($mbx in $Mailbox) {
            $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop
            foreach ($tr in $Trustee) {
                $existing = Get-MailboxPermission -Identity $mb.Identity -User $tr -ErrorAction SilentlyContinue |
                            Where-Object { $_.AccessRights -contains 'FullAccess' -and -not $_.IsInherited }
                if ($existing) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0} -> {1}' -f $tr, $mbx) `
                        -Message 'Skipped - Full Access already granted (idempotent)'
                    continue
                }

                $results.Add([PSCustomObject]@{
                    Name          = ('{0} -> {1}' -f $tr, $mb.PrimarySmtpAddress)
                    Id            = $mb.Identity
                    Mailbox       = $mb.PrimarySmtpAddress
                    MailboxType   = "$($mb.RecipientTypeDetails)"
                    MailboxOwner  = $mb.DisplayName
                    Trustee       = $tr
                    AccessRight   = 'FullAccess'
                    AutoMapping   = $AutoMapping
                    ReviewBy      = if ($ExpiryDays -gt 0) { (Get-Date).AddDays($ExpiryDays) } else { $null }
                    Ticket        = $TicketReference
                    PrivacyNote   = 'Trustee will be able to read all mail in this mailbox'
                })
            }
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Grant Full Access', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Grant Full Access')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Add-MailboxPermission -Identity $item.Mailbox -User $item.Trustee -AccessRights FullAccess `
                -AutoMapping:$item.AutoMapping -Confirm:$false -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Full Access granted. AutoMapping={0} Ticket={1} Approval={2}. Review by {3}' -f
                $item.AutoMapping, $TicketReference, $ApprovalReference,
                $(if ($item.ReviewBy) { $item.ReviewBy.ToString('yyyy-MM-dd') } else { 'not set' }))
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'FullAccessGranted'
                Detail = ('automapping {0}' -f $item.AutoMapping); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Full Access Addition on Mailbox'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
