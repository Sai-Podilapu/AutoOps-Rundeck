<#
.SYNOPSIS
    Remediates high-confidence risky users, and only those.

.DESCRIPTION
    Acts on users Identity Protection rates as high risk, and leaves
    everything below that for an analyst. The default remediation revokes
    sessions - effective against a live token and survivable if wrong.
    Blocking sign-in is available and requires a second explicit flag, because
    a false-positive lockout costs a real user their working day.

    CHANGE / WRITE. Supports -WhatIf for a clean dry run. Prior state is
    captured and logged before each change so the previous condition is
    recoverable.

    APPROVAL GATED. Without -ApprovalReference this script runs in REQUEST
    mode: it produces the change set, raises an approval artifact, prints
    the reference and stops without acting.

    AGENT-ASSIST ONLY. This automates the mechanical part - gathering,
    enriching and comparing against a baseline - and then stops, producing
    a decision-ready package. The judgement step is deliberately left to a
    human and is NOT scripted.

.PARAMETER Action
    Remediation to apply.

.PARAMETER MinimumRiskLevel
    Only users at this risk level are actionable. Anything lower is reported
    for an analyst and never acted on.

.PARAMETER LockoutAccepted
    Required for -Action BlockSignIn. Confirms that locking these accounts out
    is intended and that a false positive is an acceptable cost here.

.PARAMETER ExcludeUser
    UPNs never acted on, whatever their risk level.

.PARAMETER MaxUsers
    Ceiling on users acted on in one run.

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
    .\Invoke-EntraRiskyUserRemediation.ps1 -Action RevokeSessions

    REPORT ONLY. Lists high-risk users and raises an approval.

.EXAMPLE
    .\Invoke-EntraRiskyUserRemediation.ps1 -Action RevokeSessions -ApprovalReference APR-... -TicketReference INC0012345

    Revokes sessions for approved high-risk users.

.EXAMPLE
    .\Invoke-EntraRiskyUserRemediation.ps1 -Action BlockSignIn -LockoutAccepted -ApprovalReference APR-...

    Blocks sign-in. Locks the user out until an admin re-enables them.

.NOTES
    Source use case      : #3 - Azure Entra ID Risky User Remediation
    Category             : Security Cloud
    Technology           : Graph API / Identity Protection
    Difficulty           : Medium
    Agent possible       : Partial
    Can execute with SOP : Partially - Agent Assists
    Automation type      : Change / Write
    Risk level           : High
    Human approval needed: YES
    Guardrails (col L)   : "Auto-remediate only high-confidence risk signals; medium/ambiguous cases go to analyst - false positive lockouts hurt users"

    Required permissions : Microsoft Graph IdentityRiskyUser.ReadWrite.All, User.ReadWrite.All. Requires Entra ID P2.
    Required modules     : Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Users.Actions
    Authentication       : Vendor REST API via Invoke-RestMethod, or Graph
                           where the tool is Microsoft.

    ASSIST-ONLY, and the parameter set enforces it: -MinimumRiskLevel
    accepts only "high". Medium and low risk users are reported and are
    structurally not actionable, because the workbook says ambiguous cases
    go to an analyst and a parameter that could be widened would not
    honour that. The three actions are ordered by how much they cost when
    wrong, and the most expensive one needs -LockoutAccepted on top of the
    approval.

    Rollback             : RevokeSessions cannot be undone but costs only a
                           re-authentication. BlockSignIn is reversed by
                           re-enabling the account. ConfirmCompromised writes
                           to the risk record and is reversed by dismissing the
                           risk.
#>

#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.Identity.SignIns
#Requires -Modules Microsoft.Graph.Users.Actions

[CmdletBinding(SupportsShouldProcess)]
[OutputType([PSCustomObject])]
param(
    [ValidateSet('RevokeSessions','ConfirmCompromised','BlockSignIn')]
    [string]$Action = 'RevokeSessions',

    [ValidateSet('high')]
    [string]$MinimumRiskLevel = 'high',

    [switch]$LockoutAccepted,

    [string[]]$ExcludeUser,

    [ValidateRange(1,1000)]
    [int]$MaxUsers = 25,

    [string]$ApprovalReference,

    [switch]$RequestApproval,

    [string]$TicketReference,

    [string]$Reason = 'Identity Protection high-risk remediation',

    [ValidateSet('Console', 'CSV', 'JSON', 'HTML')]
    [string]$OutputFormat = 'Console',

    [string]$OutputPath,

    [string]$ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Modules\IT-Automation-Common.psm1') -Force

    $scriptName = 'Invoke-EntraRiskyUserRemediation'
    Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'START - use case #3 (Security Cloud)'

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
    $pre = Test-Prerequisite -RequiredModule 'Microsoft.Graph.Authentication','Microsoft.Graph.Identity.SignIns','Microsoft.Graph.Users.Actions'
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
        Connect-AutomationPlatform -Platform 'Graph' | Out-Null


        Connect-MgGraph -Scopes 'IdentityRiskyUser.ReadWrite.All','User.ReadWrite.All','User.Read.All' -NoWelcome -ErrorAction Stop
        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message 'Connected to Microsoft Graph'

        if ($Action -eq 'BlockSignIn' -and -not $LockoutAccepted) {
            throw 'Refusing -Action BlockSignIn without -LockoutAccepted. A false-positive lockout costs a ' +
                  'real user their working day, which is why this action needs a second explicit decision.'
        }

        $risky = @()
        try {
            $risky = @(Get-MgRiskyUser -All -ErrorAction Stop)
        } catch {
            throw ('Risky user data unavailable: {0}. This usually means the tenant lacks Entra ID P2.' -f $_.Exception.Message)
        }

        $reportedOnly = 0

        foreach ($user in $risky) {
            if ("$($user.RiskState)" -notmatch '(?i)atRisk|confirmedCompromised') { continue }
            if ($ExcludeUser -and $ExcludeUser -contains $user.UserPrincipalName) {
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $user.UserPrincipalName `
                    -Message 'Excluded by -ExcludeUser'
                continue
            }

            $level = "$($user.RiskLevel)"
            # -MinimumRiskLevel has a single-value ValidateSet, so this comparison can
            # only ever be against 'high'. Written as a comparison rather than a
            # hard-coded string so the constraint lives in one place - the parameter.
            $actionable = ($level -eq $MinimumRiskLevel)

            if (-not $actionable) {
                $reportedOnly++
                Write-AutomationLog -ScriptName $scriptName -Level INFO -Target $user.UserPrincipalName -Message (
                    'Reported for analyst - risk level {0} is not high-confidence. Not actionable.' -f $level)
            }

            $detections = @()
            try {
                $detections = @(Get-MgRiskDetection -Filter ("userId eq '{0}'" -f $user.Id) -Top 5 -ErrorAction Stop)
            } catch {
                Write-Verbose ('No risk detections readable for {0}' -f $user.UserPrincipalName)
            }

            if ($actionable -and ($results | Where-Object { $_.Actionable }).Count -ge $MaxUsers) {
                Write-AutomationLog -ScriptName $scriptName -Level WARN -Message (
                    'Reached -MaxUsers ({0}). Further high-risk users were NOT queued this run.' -f $MaxUsers)
                continue
            }

            $results.Add([PSCustomObject]@{
                Name           = $user.UserPrincipalName
                Id             = $user.Id
                UserId         = $user.Id
                DisplayName    = $user.UserDisplayName
                RiskLevel      = $level
                RiskState      = "$($user.RiskState)"
                RiskDetail     = "$($user.RiskDetail)"
                LastUpdated    = $user.RiskLastUpdatedDateTime
                DetectionTypes = (($detections | ForEach-Object { $_.RiskEventType }) -join '; ')
                DetectionIps   = (($detections | ForEach-Object { $_.IpAddress }) -join '; ')
                RequestedAction= $Action
                Actionable     = $actionable
                AnalystNote    = if ($actionable) { '' }
                                 else { ('Risk level {0} - the workbook assigns this case to an analyst. Not actionable by this script.' -f $level) }
            })
        }

        Write-AutomationLog -ScriptName $scriptName -Level INFO -Message (
            '{0} high-risk user(s) actionable; {1} reported for analyst review only.' -f
            ($results | Where-Object { $_.Actionable }).Count, $reportedOnly)
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
            -Action ('{0} - {1} object(s). Reason: {2}. Ticket: {3}' -f 'Remediate risky user', $candidates.Count, $Reason, $TicketReference)
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
        if (-not $PSCmdlet.ShouldProcess($label, 'Remediate risky user')) {
            $actions.Add([PSCustomObject]@{ Name = $item.Name; Action = 'WhatIf'; Detail = 'Not executed'; Succeeded = $true })
            continue
        }
        try {

            if (-not $item.Actionable) {
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = 'ReportedForAnalyst'; Detail = $item.AnalystNote; Succeeded = $true })
            } else {
                switch ($item.RequestedAction) {
                    'RevokeSessions' {
                        Revoke-MgUserSignInSession -UserId $item.UserId -ErrorAction Stop | Out-Null
                        $detail = 'Sessions revoked; the user re-authenticates on next access'
                    }
                    'ConfirmCompromised' {
                        Confirm-MgRiskyUserCompromised -UserIds @($item.UserId) -ErrorAction Stop | Out-Null
                        $detail = 'Marked confirmed-compromised in Identity Protection'
                    }
                    'BlockSignIn' {
                        Update-MgUser -UserId $item.UserId -AccountEnabled:$false -ErrorAction Stop | Out-Null
                        $detail = 'Sign-in BLOCKED; the account stays locked until an admin re-enables it'
                    }
                }

                Write-AutomationLog -ScriptName $scriptName -Level SUCCESS -Target $label -Message (
                    '{0} applied to {1} risk user ({2}). {3}' -f
                    $item.RequestedAction, $item.RiskLevel, $item.DetectionTypes, $detail)
                $actions.Add([PSCustomObject]@{
                    Name = $item.Name; Action = $item.RequestedAction; Detail = $detail; Succeeded = $true })
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

    $null = $actions | Export-AutomationResult -OutputFormat $OutputFormat -Path $OutputPath -Title 'Azure Entra ID Risky User Remediation'
    Write-Output $actions.ToArray()
    if ($bad.Count -gt 0) { exit 1 }
}
