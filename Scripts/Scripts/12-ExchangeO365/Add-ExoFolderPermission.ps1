<#
.SYNOPSIS
    Grants explicit permission on a mailbox folder.

.DESCRIPTION
    Grants folder-level access, typically to a calendar or a shared subfolder.
    More granular than Full Access and therefore preferable where it meets the
    need, but still an access grant to someone else's data, so it is
    approval-gated.

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

.PARAMETER FolderPath
    Folder relative to the mailbox root, e.g. :\\Calendar or :\\Inbox\\Shared.

.PARAMETER AccessRight
    Exchange folder access right to grant.

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
    .\Add-ExoFolderPermission.ps1 -Mailbox user@contoso.com -Trustee peer@contoso.com -FolderPath ':\\Calendar' -AccessRight Reviewer -TicketReference REQ0012345

    REQUEST mode - raises an approval for calendar read access.

.EXAMPLE
    .\Add-ExoFolderPermission.ps1 -Mailbox user@contoso.com -Trustee peer@contoso.com -FolderPath ':\\Calendar' -ApprovalReference APR-...

    Applies the approved grant.

.NOTES
    Source use case      : #9 - Explicit Folder Permission Addition
    Category             : Exchange & O365
    Technology           : Exchange/EXO PowerShell
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Access grant; approval via ticket"

    Required permissions : Exchange Online Organization Management, or Mail Recipients role.
    Required modules     : ExchangeOnlineManagement
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    Reviewer grants read access; Editor allows modification and deletion.
    The default here is Reviewer deliberately - escalate only if the
    request genuinely needs write access.

    Rollback             : Remove-ExoFolderPermission.ps1.
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

    [Parameter(Mandatory)]
    [string]$FolderPath,

    [ValidateSet('Owner','PublishingEditor','Editor','PublishingAuthor','Author','NonEditingAuthor','Reviewer','Contributor','AvailabilityOnly','LimitedDetails')]
    [string]$AccessRight = 'Reviewer',

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Folder permission grant',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Add-ExoFolderPermission'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #9 (Exchange & O365)'

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

        foreach ($mbx in $Mailbox) {
            $mb = Get-Mailbox -Identity $mbx -ErrorAction Stop
            $folderId = '{0}{1}' -f $mb.PrimarySmtpAddress, $FolderPath

            # Fail early if the folder path is wrong, rather than at grant time.
            try { Get-MailboxFolderPermission -Identity $folderId -ErrorAction Stop | Out-Null }
            catch { throw ('Folder "{0}" not found on {1}: {2}' -f $FolderPath, $mb.PrimarySmtpAddress, $_.Exception.Message) }

            foreach ($tr in $Trustee) {
                $existing = Get-MailboxFolderPermission -Identity $folderId -User $tr -ErrorAction SilentlyContinue
                if ($existing -and $existing.AccessRights -contains $AccessRight) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target ('{0} -> {1}' -f $tr, $folderId) `
                        -Message ('Skipped - already has {0} (idempotent)' -f $AccessRight)
                    continue
                }

                $results.Add([PSCustomObject]@{
                    Name          = ('{0} -> {1}{2}' -f $tr, $mb.PrimarySmtpAddress, $FolderPath)
                    Id            = $folderId
                    Mailbox       = $mb.PrimarySmtpAddress
                    FolderPath    = $FolderPath
                    FolderId      = $folderId
                    Trustee       = $tr
                    AccessRight   = $AccessRight
                    ExistingRight = if ($existing) { ($existing.AccessRights -join ',') } else { $null }
                    IsUpdate      = [bool]$existing
                    Ticket        = $TicketReference
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Grant folder permission', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Grant folder permission')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.IsUpdate) {
                Set-MailboxFolderPermission -Identity $item.FolderId -User $item.Trustee `
                    -AccessRights $item.AccessRight -Confirm:$false -ErrorAction Stop | Out-Null
                $verb = 'updated'
            } else {
                Add-MailboxFolderPermission -Identity $item.FolderId -User $item.Trustee `
                    -AccessRights $item.AccessRight -Confirm:$false -ErrorAction Stop | Out-Null
                $verb = 'granted'
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Folder permission {0}: {1} (was {2}). Ticket={3}' -f
                $verb, $item.AccessRight, $(if ($item.ExistingRight) { $item.ExistingRight } else { 'none' }), $TicketReference)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = ('FolderPermission' + $verb); Detail = $item.AccessRight; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Explicit Folder Permission Addition'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
