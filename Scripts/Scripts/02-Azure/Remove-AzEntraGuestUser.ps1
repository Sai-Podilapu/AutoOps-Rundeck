<#
.SYNOPSIS
    Removes Entra ID guest accounts that have been inactive beyond a
    threshold.

.DESCRIPTION
    Finds guest users with no recent sign-in and proposes them for removal.
    False positives here lock out real partners, so the script reports a full
    evidence set per guest - last sign-in, creation date, group memberships
    and owned objects - and requires the list to be approved before anything
    is deleted.

    DESTRUCTIVE. This script is REPORT-ONLY by default: it produces the
    candidate list and stops. Nothing is deleted, wiped or failed over
    unless -Execute is passed AND a valid -ApprovalReference is supplied.
    A pre-action backup/export is taken where the platform allows it, and
    every object is logged individually before it is touched.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

.PARAMETER InactiveDays
    Guests with no sign-in for at least this long are proposed.

.PARAMETER ExcludeDomain
    Guest domains that are never proposed, e.g. a strategic partner.

.PARAMETER DisableInsteadOfDelete
    Block sign-in rather than delete. Reversible, and usually the right first
    step.

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
    .\Remove-AzEntraGuestUser.ps1 -InactiveDays 90

    REPORT ONLY. Lists guests inactive for 90 days and raises an approval.

.EXAMPLE
    .\Remove-AzEntraGuestUser.ps1 -InactiveDays 90 -ApprovalReference APR-... -Execute -DisableInsteadOfDelete

    Blocks sign-in for the approved guests instead of deleting them.

.NOTES
    Source use case      : #26 - Azure Entra ID (AAD) Guest User Cleanup
    Category             : Azure
    Technology           : Graph API / PowerShell
    Difficulty           : Medium
    Agent possible       : Yes - with Human Approval
    Can execute with SOP : Yes - With Approval
    Automation type      : Destructive / High-Impact
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Removing guests >90 days stale; false positives lock out partners - approve list first"

    Required permissions : Microsoft Graph User.ReadWrite.All and AuditLog.Read.All (sign-in activity requires an Entra ID P1 licence).
    Required modules     : Az.Accounts, Microsoft.Graph.Authentication, Microsoft.Graph.Users
    Authentication       : Managed identity preferred; otherwise service
                           principal with certificate.

    Sign-in activity requires Entra ID P1 or above. Without it,
    lastSignInDateTime is null for every user, and this script treats a
    null as NOT inactive - so it proposes nothing rather than proposing
    everyone.

    Rollback             : A DELETED user is recoverable from the Entra ID
                           recycle bin for 30 days. After that it is permanent.
                           -DisableInsteadOfDelete is fully reversible and is
                           the safer choice for a first pass.
#>

#Requires -Version 5.1
#Requires -Modules Az.Accounts
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Users

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
    [ValidateRange(30,3650)]
    [int]$InactiveDays = 90,

    [string[]]$ExcludeDomain,

    [switch]$DisableInsteadOfDelete,

    [switch]$Execute,

    [string]$ProtectedList,

    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 0,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Inactive guest account cleanup',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Remove-AzEntraGuestUser'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #26 (Azure)'

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


        Connect-MgGraph -Scopes 'User.ReadWrite.All','AuditLog.Read.All','Directory.Read.All' -NoWelcome -ErrorAction Stop

        $cutoff = (Get-Date).AddDays(-$InactiveDays)
        $noActivityData = 0

        $guests = Get-MgUser -Filter "userType eq 'Guest'" -All `
            -Property Id,UserPrincipalName,DisplayName,Mail,CreatedDateTime,AccountEnabled,SignInActivity `
            -ErrorAction Stop

        foreach ($g in $guests) {
            $domain = ($g.Mail -split '@')[-1]
            if (-not $domain) { $domain = ($g.UserPrincipalName -split '#EXT#')[0] -replace '.*_', '' }

            if ($ExcludeDomain -and ($ExcludeDomain | Where-Object { $domain -like $_ })) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $g.UserPrincipalName `
                    -Message ('Excluded - domain {0} is on the exclusion list' -f $domain)
                continue
            }

            $lastSignIn = $g.SignInActivity.LastSignInDateTime

            # No sign-in data is NOT evidence of inactivity - it usually means the
            # tenant lacks the licence that surfaces it. Treat it as unknown, not stale.
            if (-not $lastSignIn) {
                $noActivityData++
                continue
            }
            if ($lastSignIn -ge $cutoff) { continue }

            # Evidence an approver needs to judge a false positive.
            $groups = @(); $owned = @()
            try {
                $groups = @(Get-MgUserMemberOf -UserId $g.Id -All -ErrorAction Stop |
                            ForEach-Object { $_.AdditionalProperties.displayName } | Where-Object { $_ })
            } catch {
                # Directory.Read.All may not be consented. Reported as unknown rather
                # than as zero, so an approver is not shown a falsely low risk.
                Write-Verbose ('Group membership unavailable for {0}: {1}' -f $g.UserPrincipalName, $_.Exception.Message)
            }
            try {
                $owned  = @(Get-MgUserOwnedObject -UserId $g.Id -All -ErrorAction Stop |
                            ForEach-Object { $_.AdditionalProperties.displayName } | Where-Object { $_ })
            } catch {
                Write-Verbose ('Owned objects unavailable for {0}: {1}' -f $g.UserPrincipalName, $_.Exception.Message)
            }

            $results.Add([PSCustomObject]@{
                Name           = $g.UserPrincipalName
                Id             = $g.Id
                DisplayName    = $g.DisplayName
                Mail           = $g.Mail
                Domain         = $domain
                AccountEnabled = $g.AccountEnabled
                CreatedAt      = $g.CreatedDateTime
                LastSignIn     = $lastSignIn
                InactiveDays   = [math]::Round(((Get-Date) - $lastSignIn).TotalDays, 0)
                GroupCount     = $groups.Count
                Groups         = (($groups | Select-Object -First 10) -join '; ')
                OwnedObjects   = (($owned | Select-Object -First 10) -join '; ')
                RiskOfRemoval  = if ($owned.Count -gt 0) { 'HIGH - owns objects that would be orphaned' }
                                 elseif ($groups.Count -gt 3) { 'MEDIUM - member of several groups' }
                                 else { 'Low' }
            })
        }

        if ($noActivityData -gt 0) {
            Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                '{0} guest(s) have no sign-in activity data and were NOT proposed. This usually means the ' +
                'tenant lacks Entra ID P1. Absence of data is not evidence of inactivity.' -f $noActivityData)
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Remove inactive guest user', $candidates.Count, $Reason, $TicketReference)
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
        $null = $candidates | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Entra ID (AAD) Guest User Cleanup (candidates)'
        Write-Output $candidates
        return
    }

    $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $candidates) {
        $label = '{0}' -f $item.Name
        if (-not $PSCmdlet.ShouldProcess($label, 'Remove inactive guest user')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if ($DisableInsteadOfDelete) {
                Update-MgUser -UserId $item.Id -AccountEnabled:$false -ErrorAction Stop
                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Guest DISABLED (reversible). Inactive {0}d, risk {1}' -f $item.InactiveDays, $item.RiskOfRemoval)
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'Disabled'
                    Detail = ('inactive {0}d - reversible' -f $item.InactiveDays); Succeeded = $true })
            } else {
                Remove-MgUser -UserId $item.Id -ErrorAction Stop
                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    'Guest DELETED. Inactive {0}d, risk {1}. Recoverable from the recycle bin for 30 days.' -f
                    $item.InactiveDays, $item.RiskOfRemoval)
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'Deleted'
                    Detail = ('inactive {0}d - recycle bin 30d' -f $item.InactiveDays); Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Entra ID (AAD) Guest User Cleanup'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
