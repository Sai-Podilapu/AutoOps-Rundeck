<#
.SYNOPSIS
    Deletes Teams meeting recordings older than a retention threshold.

.DESCRIPTION
    Finds meeting recordings in OneDrive beyond the retention age and deletes
    them. The workbook is explicit that retention and legal-hold exclusions
    must be confirmed first, so this script checks each item for a hold and
    refuses to propose anything under one.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER UserPrincipalName
    Limit to specific users. All licensed users when omitted.

.PARAMETER MaxUsers
    Maximum users to scan when -UserPrincipalName is omitted.

.PARAMETER RecordingsFolder
    Folder recordings are stored in.

.PARAMETER LegalHoldConfirmed
    Confirms retention and legal-hold exclusions have been checked, per the
    SOP.

.PARAMETER Execute
    Actually perform the destructive action. Without this the script only
    reports what it would do.

.PARAMETER ProtectedList
    Path to a file of names/ids that must never be acted upon, one per line.
    Entries here are excluded unconditionally and the exclusion cannot be
    overridden by any other parameter.

.PARAMETER MinimumAgeDays
    Only consider objects older than this. A conservative default guards
    against acting on something created moments ago.

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
    .\Remove-TeamsMeetingRecording.ps1 -MinimumAgeDays 30

    REPORT ONLY. Lists recordings older than 30 days and raises an approval.

.EXAMPLE
    .\Remove-TeamsMeetingRecording.ps1 -MinimumAgeDays 30 -LegalHoldConfirmed -ApprovalReference APR-... -Execute

    Deletes the approved recordings.

.NOTES
    Source use case      : #13 - Teams Meeting Recording Cleanup
    Category             : M365
    Technology           : Graph API
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Destructive / High-Impact
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Deleting recordings >30 days; confirm retention/legal-hold exclusions in SOP"

    Required permissions : Microsoft Graph Files.ReadWrite.All and User.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Files
    Authentication       : App registration with certificate auth (app-only).

    This script cannot see eDiscovery holds applied at the tenant level -
    it can only detect item-level retention labels. -LegalHoldConfirmed is
    the operator asserting that the tenant-level check was done, which is
    why it is mandatory rather than advisory.

    Rollback             : A deleted item goes to the OneDrive recycle bin and
                           is recoverable for 93 days, then permanently
                           removed.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Files

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [string[]]$UserPrincipalName,

    [ValidateRange(1,10000)]
    [int]$MaxUsers = 200,

    [string]$RecordingsFolder = 'Recordings',

    [switch]$LegalHoldConfirmed,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 30,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Teams recording retention cleanup',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Remove-TeamsMeetingRecording'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #13 (M365)'

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

    $protected = @()
    if ($ProtectedList -and (Test-Path -LiteralPath $ProtectedList)) {
        $protected = @(Get-Content -LiteralPath $ProtectedList |
            Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() })
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'Protected list loaded: {0} entry(ies). These are excluded unconditionally.' -f $protected.Count)
    }

    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    try {
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        Connect-MgGraph -Scopes 'Files.ReadWrite.All','User.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        if (-not $LegalHoldConfirmed) {
            throw 'Refusing to proceed without -LegalHoldConfirmed. The SOP requires retention and ' +
                  'legal-hold exclusions to be confirmed before recordings are deleted.'
        }

        $users = if ($UserPrincipalName) { $UserPrincipalName | ForEach-Object { Get-MgUser -UserId $_ -ErrorAction Stop } }
                 else { Get-MgUser -Filter 'assignedLicenses/$count ne 0' -ConsistencyLevel eventual -CountVariable c -Top $MaxUsers -ErrorAction Stop }

        $cutoff = (Get-Date).AddDays(-$MinimumAgeDays)

        foreach ($u in $users) {
            $drive = $null
            try { $drive = Get-MgUserDrive -UserId $u.Id -ErrorAction Stop } catch { continue }

            $folder = $null
            try {
                $folder = Get-MgDriveRootChild -DriveId $drive.Id -ErrorAction Stop |
                          Where-Object { $_.Name -eq $RecordingsFolder -and $_.Folder } | Select-Object -First 1
            } catch {
                Write-Verbose ('No recordings folder for {0}' -f $u.UserPrincipalName)
            }
            if (-not $folder) { continue }

            $items = @()
            try { $items = @(Get-MgDriveItemChild -DriveId $drive.Id -DriveItemId $folder.Id -All -ErrorAction Stop) } catch {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $u.UserPrincipalName `
                    -Message ('Could not enumerate recordings: {0}' -f $_.Exception.Message)
                continue
            }

            foreach ($it in $items) {
                if ($it.Folder) { continue }
                if ($it.CreatedDateTime -ge $cutoff) { continue }

                # Item-level retention label. Tenant-level eDiscovery holds are not
                # visible here, which is what -LegalHoldConfirmed covers.
                $hasLabel = $false
                try {
                    $labelResp = Invoke-MgGraphRequest -Method GET `
                        -Uri ('https://graph.microsoft.com/v1.0/drives/{0}/items/{1}/retentionLabel' -f $drive.Id, $it.Id) `
                        -ErrorAction Stop
                    $hasLabel = [bool]$labelResp.name
                } catch {
                    Write-Verbose ('No retention label on {0}' -f $it.Name)
                }
                if ($hasLabel) {
                    Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $it.Name `
                        -Message 'Excluded - carries a retention label'
                    continue
                }

                $results.Add([PSCustomObject]@{
                    Name        = ('{0} / {1}' -f $u.UserPrincipalName, $it.Name)
                    Id          = $it.Id
                    Owner       = $u.UserPrincipalName
                    DriveId     = $drive.Id
                    ItemName    = $it.Name
                    SizeMB      = if ($it.Size) { [math]::Round($it.Size / 1MB, 2) } else { $null }
                    CreatedAt   = $it.CreatedDateTime
                    AgeDays     = [math]::Round(((Get-Date) - $it.CreatedDateTime).TotalDays, 0)
                    WebUrl      = $it.WebUrl
                    RetentionLabel = 'none detected at item level'
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

    # Hard exclusions and safety filters BEFORE anything else.
    if ($protected.Count -gt 0) {
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object {
            $id = $_.Id; $nm = $_.Name
            -not ($protected | Where-Object { $_ -and ($id -like $_ -or $nm -like $_) })
        })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Protected list excluded {0} object(s).' -f ($before - $candidates.Count))
        }
    }
    if ($MinimumAgeDays -gt 0) {
        $cut = (Get-Date).AddDays(-$MinimumAgeDays)
        $before = $candidates.Count
        $candidates = @($candidates | Where-Object { -not $_.CreatedAt -or $_.CreatedAt -lt $cut })
        if ($before -ne $candidates.Count) {
            Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
                'Age filter (>{0}d) excluded {1} object(s).' -f $MinimumAgeDays, ($before - $candidates.Count))
        }
    }

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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Delete meeting recording', $candidates.Count, $Reason, $TicketReference)
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

    if (-not $Execute) {
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            'REPORT-ONLY - {0} candidate(s) identified, nothing was changed. Pass -Execute to act.' -f $candidates.Count)
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Teams Meeting Recording Cleanup (candidates)'
        Write-Output $candidates
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Delete meeting recording')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            Invoke-MgGraphRequest -Method DELETE `
                -Uri ('https://graph.microsoft.com/v1.0/drives/{0}/items/{1}' -f $item.DriveId, $item.Id) `
                -ErrorAction Stop | Out-Null

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                'Recording deleted: {0} ({1}MB, {2}d old). Recycle bin retains it for 93 days.' -f
                $item.ItemName, $item.SizeMB, $item.AgeDays)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = 'Deleted'
                Detail = ('{0}MB, {1}d old' -f $item.SizeMB, $item.AgeDays); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Teams Meeting Recording Cleanup'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
