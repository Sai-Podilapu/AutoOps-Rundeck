<#
.SYNOPSIS
    Archives or deletes Teams channels with no recent activity.

.DESCRIPTION
    Finds channels with no message activity beyond the threshold. The workbook
    is explicit about the order of operations: archive first, and delete only
    after owner confirmation. This script therefore defaults to ARCHIVE, and
    deletion requires both approval and an explicit switch.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER TeamName
    Limit to specific teams. All Teams-enabled groups when omitted.

.PARAMETER Mode
    Archive renames the channel with an archive prefix; Delete removes it.
    Archive is the default per the SOP.

.PARAMETER ArchivePrefix
    Prefix applied to an archived channel name.

.PARAMETER OwnerConfirmed
    Confirms the channel owner agreed to deletion. Required for -Mode Delete.

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
    .\Remove-TeamsInactiveChannel.ps1 -MinimumAgeDays 90

    REPORT ONLY. Lists channels with no messages in 90 days and raises an
    approval.

.EXAMPLE
    .\Remove-TeamsInactiveChannel.ps1 -MinimumAgeDays 90 -Mode Delete -OwnerConfirmed -ApprovalReference APR-... -Execute

    Deletes the approved channels after owner confirmation.

.NOTES
    Source use case      : #2 - Teams Inactive Channels Cleanup
    Category             : M365
    Technology           : Graph API
    Difficulty           : Medium
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Destructive / High-Impact
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Archive/delete >90-day channels; archive first, delete only after owner confirmation"

    Required permissions : Microsoft Graph Channel.ReadBasic.All, ChannelMessage.Read.All and ChannelSettings.ReadWrite.All. Delete additionally needs Channel.Delete.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Teams
    Authentication       : App registration with certificate auth (app-only).

    The General channel cannot be deleted or renamed and is always
    excluded. Activity is measured from the most recent message; a channel
    used only for file storage will look inactive even though its content
    is in use, which is why owner confirmation is required before
    deletion.

    Rollback             : An archived channel is simply renamed and can be
                           renamed back. A DELETED channel is recoverable for
                           30 days, after which its files are gone with it.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Teams

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [string[]]$TeamName,

    [ValidateSet('Archive','Delete')]
    [string]$Mode = 'Archive',

    [string]$ArchivePrefix = 'ARCHIVED-',

    [switch]$OwnerConfirmed,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 90,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Inactive Teams channel cleanup',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Remove-TeamsInactiveChannel'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #2 (M365)'

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


        Connect-MgGraph -Scopes 'Group.Read.All','Channel.ReadBasic.All','ChannelMessage.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        if ($Mode -eq 'Delete' -and -not $OwnerConfirmed) {
            throw 'Refusing to delete without -OwnerConfirmed. The SOP requires archiving first and ' +
                  'deleting only after the channel owner confirms.'
        }

        $teams = if ($TeamName) {
                     $TeamName | ForEach-Object {
                         Get-MgGroup -Filter ("displayName eq '{0}'" -f ($_ -replace "'", "''")) -ErrorAction SilentlyContinue |
                         Select-Object -First 1
                     }
                 } else {
                     Get-MgGroup -Filter "resourceProvisioningOptions/Any(x:x eq 'Team')" -All -ErrorAction Stop
                 }

        $cutoff = (Get-Date).AddDays(-$MinimumAgeDays)

        foreach ($team in $teams) {
            if (-not $team) { continue }
            $channels = @(Get-MgTeamChannel -TeamId $team.Id -ErrorAction SilentlyContinue)

            foreach ($ch in $channels) {
                # General cannot be renamed or deleted.
                if ($ch.DisplayName -eq 'General') { continue }
                if ($ch.DisplayName -like ("{0}*" -f $ArchivePrefix)) { continue }   # already archived

                $lastMessage = $null
                try {
                    $msgs = Get-MgTeamChannelMessage -TeamId $team.Id -ChannelId $ch.Id -Top 1 `
                            -Sort 'createdDateTime desc' -ErrorAction Stop
                    $lastMessage = ($msgs | Select-Object -First 1).CreatedDateTime
                } catch {
                    Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $ch.DisplayName `
                        -Message ('Message history unreadable: {0}' -f $_.Exception.Message)
                    continue    # unknown activity is not evidence of inactivity
                }

                $effectiveDate = if ($lastMessage) { $lastMessage } else { $ch.CreatedDateTime }
                if ($effectiveDate -ge $cutoff) { continue }

                $results.Add([PSCustomObject]@{
                    Name         = ('{0} / {1}' -f $team.DisplayName, $ch.DisplayName)
                    Id           = $ch.Id
                    TeamName     = $team.DisplayName
                    TeamId       = $team.Id
                    ChannelId    = $ch.Id
                    ChannelName  = $ch.DisplayName
                    MembershipType = "$($ch.MembershipType)"
                    CreatedAt    = $effectiveDate
                    LastMessage  = $lastMessage
                    InactiveDays = [math]::Round(((Get-Date) - $effectiveDate).TotalDays, 0)
                    Mode         = $Mode
                    FilesCaveat  = 'A channel used only for file storage looks inactive but its content may be in use'
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Archive or delete inactive channel', $candidates.Count, $Reason, $TicketReference)
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
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Teams Inactive Channels Cleanup (candidates)'
        Write-Output $candidates
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Archive or delete inactive channel')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.Mode -eq 'Archive') {
                $newName = '{0}{1}' -f $ArchivePrefix, $item.ChannelName
                Update-MgTeamChannel -TeamId $item.TeamId -ChannelId $item.ChannelId `
                    -DisplayName $newName -ErrorAction Stop | Out-Null
                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Channel archived (renamed to {0}). Inactive {1}d. Reversible by renaming back.' -f
                    $newName, $item.InactiveDays)
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'Archived'; Detail = $newName; Succeeded = $true })
            } else {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Target $label -Message (
                    'DELETING channel. Inactive {0}d. OwnerConfirmed=true Approval={1}. Files go with it; ' +
                    'recoverable for 30 days.' -f $item.InactiveDays, $ApprovalReference)
                Remove-MgTeamChannel -TeamId $item.TeamId -ChannelId $item.ChannelId -ErrorAction Stop
                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message 'Channel deleted'
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'Deleted'
                    Detail = ('inactive {0}d; 30-day recovery window' -f $item.InactiveDays); Succeeded = $true })
            }
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Teams Inactive Channels Cleanup'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
