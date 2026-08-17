<#
.SYNOPSIS
    Grants Send As permission on a mailbox.

.DESCRIPTION
    Allows a trustee to send mail that appears to come FROM the mailbox owner,
    with no visible indication that somebody else sent it. That is
    impersonation, and it is the reason this row is High risk with strict
    approval: a Send As grant enables convincing internal phishing.

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
    .\Add-ExoSendAsPermission.ps1 -Mailbox shared@contoso.com -Trustee user@contoso.com -TicketReference REQ0012345

    REQUEST mode - raises an approval for an impersonation-capable grant.

.EXAMPLE
    .\Add-ExoSendAsPermission.ps1 -Mailbox shared@contoso.com -Trustee user@contoso.com -ApprovalReference APR-...

    Applies the approved grant.

.NOTES
    Source use case      : #12 - Provisioning 'Send As' Permissions
    Category             : Exchange & O365
    Technology           : Exchange/EXO PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Impersonation-capable permission; strict approval"

    Required permissions : Exchange Online Organization Management, or a custom role with Recipient Permissions.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    Consider Send on Behalf instead wherever it meets the requirement.
    Send on Behalf is visibly attributed to the delegate; Send As is
    indistinguishable from the owner sending it themselves, including to
    the recipient and in most audit views.

    Rollback             : Remove-ExoSendAsPermission.ps1. Immediately
                           reversible, but any mail already sent under the
                           owner\u2019s identity cannot be recalled or
                           re-attributed.
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

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Send As permission grant',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Add-ExoSendAsPermission'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #12 (Exchange & O365)'

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
            throw 'A -TicketReference is required. Send As is impersonation-capable and needs strict approval.'
        }

        foreach ($mbx in $Mailbox) {
            $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop

            foreach ($tr in $Trustee) {
                $existing = Get-RecipientPermission -Identity $mb.Identity -Trustee $tr -ErrorAction SilentlyContinue |
                            Where-Object { $_.AccessRights -contains 'SendAs' }
                if ($existing) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0} -> {1}' -f $tr, $mbx) `
                        -Message 'Skipped - Send As already granted (idempotent)'
                    continue
                }

                $results.Add([PSCustomObject]@{
                    Name        = ('{0} -> {1}' -f $tr, $mb.PrimarySmtpAddress)
                    Id          = $mb.Identity
                    Mailbox     = $mb.PrimarySmtpAddress
                    MailboxType = "$($mb.RecipientTypeDetails)"
                    Trustee     = $tr
                    AccessRight = 'SendAs'
                    Ticket      = $TicketReference
                    RiskNote    = 'IMPERSONATION - mail will appear to come from the owner with no visible delegate'
                    Alternative = 'Send on Behalf is visibly attributed and may meet the same need'
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Grant Send As', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Grant Send As')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                'Granting IMPERSONATION-capable Send As. Ticket={0} Approval={1}' -f $TicketReference, $ApprovalReference)

            Add-RecipientPermission -Identity $item.Mailbox -Trustee $item.Trustee -AccessRights SendAs `
                -Confirm:$false -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message 'Send As granted'
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'SendAsGranted'; Detail = 'impersonation-capable'; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Provisioning ''Send As'' Permissions'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
