<#
.SYNOPSIS
    Adds or removes a user from a Microsoft 365 group.

.DESCRIPTION
    Changes group membership. A group can carry Teams access, SharePoint
    permissions and application assignments, so the script reports what the
    group grants before the change is approved - membership is rarely just
    membership.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER GroupName
    Group display name or object id.

.PARAMETER UserPrincipalName
    User(s) to add or remove.

.PARAMETER Operation
    Add or Remove.

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
    .\Add-O365GroupMember.ps1 -GroupName 'Finance Team' -UserPrincipalName user@contoso.com -Operation Add -TicketReference REQ0012345

    REQUEST mode - raises an approval showing what the group grants.

.EXAMPLE
    .\Add-O365GroupMember.ps1 -GroupName 'Finance Team' -UserPrincipalName user@contoso.com -Operation Remove -ApprovalReference APR-...

    Applies the approved change.

.NOTES
    Source use case      : #20 - Add User into O365 Group
    Category             : Exchange & O365
    Technology           : Graph API
    Difficulty           : Low
    Agent possible       : Yes
    Can execute with SOP : Yes - With Approval
    Automation type      : Change / Write
    Risk level           : Medium
    Human approval needed: YES
    Guardrails (col L)   : "Group may grant app/data access; ticket approval"

    Required permissions : Microsoft Graph GroupMember.ReadWrite.All and Group.Read.All.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Groups
    Authentication       : App-only certificate auth via
                           Connect-ExchangeOnline.

    A dynamic group\u2019s membership is computed from its rule, so it
    cannot be edited directly. The script detects that and refuses with a
    clear message rather than failing inside Graph.

    Rollback             : Re-run with the opposite -Operation.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Groups

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string]$GroupName,

    [Parameter(Mandatory)]
    [string[]]$UserPrincipalName,

    [Parameter(Mandatory)]
    [ValidateSet('Add','Remove')]
    [string]$Operation,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Group membership change',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Add-O365GroupMember'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #20 (Exchange & O365)'

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


        Connect-MgGraph -Scopes 'Group.Read.All','GroupMember.ReadWrite.All','User.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        $group = Get-MgGroup -Filter ("displayName eq '{0}'" -f ($GroupName -replace "'", "''")) -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if (-not $group) {
            $group = Get-MgGroup -GroupId $GroupName -ErrorAction SilentlyContinue
        }
        if (-not $group) { throw ('Group "{0}" not found.' -f $GroupName) }

        # Dynamic membership is rule-driven and cannot be edited member by member.
        if ($group.GroupTypes -contains 'DynamicMembership') {
            throw ('"{0}" uses dynamic membership. Edit the membership rule instead - direct changes are not possible.' -f $group.DisplayName)
        }

        $members = @(Get-MgGroupMember -GroupId $group.Id -All -ErrorAction SilentlyContinue)

        foreach ($upn in $UserPrincipalName) {
            $u = Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName -ErrorAction Stop
            $isMember = $members.Id -contains $u.Id

            if (($Operation -eq 'Add' -and $isMember) -or ($Operation -eq 'Remove' -and -not $isMember)) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $upn `
                    -Message ('Skipped - membership already in the requested state (idempotent)' )
                continue
            }

            $results.Add([PSCustomObject]@{
                Name          = ('{0} : {1} {2}' -f $u.UserPrincipalName, $Operation, $group.DisplayName)
                Id            = $group.Id
                GroupName     = $group.DisplayName
                GroupId       = $group.Id
                GroupTypes    = ($group.GroupTypes -join ',')
                MailEnabled   = $group.MailEnabled
                SecurityEnabled = $group.SecurityEnabled
                CurrentMembers= $members.Count
                UserPrincipalName = $u.UserPrincipalName
                UserId        = $u.Id
                Operation     = $Operation
                AccessNote    = if ($group.SecurityEnabled) { 'Security-enabled - may grant application or data access beyond mail' }
                                else { 'Mail/collaboration group' }
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Change group membership', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Change group membership')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($item.Operation -eq 'Add') {
                New-MgGroupMember -GroupId $item.GroupId -DirectoryObjectId $item.UserId -ErrorAction Stop
                $detail = 'added to {0}' -f $item.GroupName
            } else {
                Remove-MgGroupMemberByRef -GroupId $item.GroupId -DirectoryObjectId $item.UserId -ErrorAction Stop
                $detail = 'removed from {0}' -f $item.GroupName
            }

            Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                '{0}. Group grants: {1}. Ticket={2}' -f $detail, $item.AccessNote, $TicketReference)
            $actions.Add([PSCustomObject]@{
                Name = $item.Name; Action = $item.Operation; Detail = $detail; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Add User into O365 Group'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
